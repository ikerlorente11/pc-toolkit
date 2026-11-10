//! Reading without connection. An item made available offline is a folder of the app's local data
//! (`offline/<account>/<item id>/`): its pages as the service already rendered them (`p/<n>.jpg`…),
//! or the file itself for a book (`file.epub`), its cover, and `item.json` (what the service said of
//! it), written last, so a folder without it is a download still going or cut short (it resumes).
//! The web view reads them through the `offline` protocol (`http://offline.localhost/<account>/<id>/p/3`
//! on Windows), so the viewer fetches a stored page like any other image, without credentials.

use std::borrow::Cow;
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::http::{Request, Response};
use tauri::{AppHandle, Emitter, Manager, Runtime, State, UriSchemeContext};

/// Pages asked at once (the service renders them; a Pi has few cores).
const WORKERS: usize = 2;
const ATTEMPTS: u32 = 3;

/// The downloads going on, by `<account>/<id>`: setting the flag stops one and deletes what it got.
#[derive(Default)]
pub struct Jobs(Mutex<HashMap<String, Arc<AtomicBool>>>);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    account: String,
    id: u64,
    /// the service's address and the credential to ask it with
    base: String,
    authorization: String,
    /// pages to fetch (0 with `file`)
    pages: u32,
    /// the whole file instead of its pages (a book)
    file: bool,
    /// the width the pages are asked in
    width: u32,
    /// what the service said of the item, kept as item.json
    meta: serde_json::Value,
}

#[derive(Serialize, Clone)]
struct Progress {
    id: u64,
    done: u32,
    total: u32,
    bytes: u64,
    error: Option<String>,
    finished: bool,
    cancelled: bool,
}

/// Only letters, digits, `_` and `-`: the account is a folder name and a piece of a URL.
fn clean(account: &str) -> String {
    let out: String = account.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).collect();
    if out.is_empty() { "_".into() } else { out }
}

fn root<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    Ok(app.path().app_local_data_dir().map_err(|e| e.to_string())?.join("offline"))
}

pub(crate) fn item_dir<R: Runtime>(app: &AppHandle<R>, account: &str, id: u64) -> Result<PathBuf, String> {
    Ok(root(app)?.join(clean(account)).join(id.to_string()))
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn extension(mime: &str) -> &'static str {
    match mime.split(';').next().unwrap_or("").trim() {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "image/avif" => "avif",
        "application/epub+zip" => "epub",
        "application/pdf" => "pdf",
        _ => "bin",
    }
}

fn mime_of(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "avif" => "image/avif",
        "epub" => "application/epub+zip",
        "pdf" => "application/pdf",
        "json" => "application/json",
        _ => "application/octet-stream",
    }
}

/// The file of `dir` whose name, without its extension, is `stem`.
fn find(dir: &Path, stem: &str) -> Option<PathBuf> {
    fs::read_dir(dir).ok()?.flatten().map(|e| e.path()).find(|p| {
        p.is_file() && p.file_stem().and_then(|s| s.to_str()) == Some(stem) && p.extension().map(|e| e != "part").unwrap_or(true)
    })
}

fn size_of(dir: &Path) -> u64 {
    fs::read_dir(dir).map(|entries| {
        entries.flatten().map(|e| {
            let p = e.path();
            if p.is_dir() { size_of(&p) } else { e.metadata().map(|m| m.len()).unwrap_or(0) }
        }).sum()
    }).unwrap_or(0)
}

/// GET with a few attempts (the service may be busy rendering); errors that will not change are not retried.
fn fetch(agent: &ureq::Agent, url: &str, authorization: &str) -> Result<ureq::Response, String> {
    let mut last = String::new();
    for attempt in 1..=ATTEMPTS {
        match agent.get(url).set("Authorization", authorization).call() {
            Ok(r) => return Ok(r),
            Err(ureq::Error::Status(code, r)) => {
                let detail = r.into_string().ok()
                    .and_then(|body| serde_json::from_str::<serde_json::Value>(&body).ok())
                    .and_then(|v| v.get("detail").and_then(|d| d.as_str()).map(String::from));
                last = detail.unwrap_or_else(|| format!("HTTP {code}"));
                if matches!(code, 400..=499) && code != 408 && code != 429 {
                    return Err(last);
                }
            }
            Err(e) => last = format!("sin conexión ({e})"),
        }
        thread::sleep(Duration::from_secs(2 * attempt as u64));
    }
    Err(last)
}

/// Saves an answer as `<dir>/<stem>.<ext>` (written aside first); its size.
fn save(response: ureq::Response, dir: &Path, stem: &str) -> Result<u64, String> {
    let ext = extension(response.header("Content-Type").unwrap_or(""));
    let part = dir.join(format!("{stem}.part"));
    let mut out = fs::File::create(&part).map_err(|e| e.to_string())?;
    let written = io::copy(&mut response.into_reader().take(4 << 30), &mut out).map_err(|e| e.to_string())?;
    drop(out);
    fs::rename(&part, dir.join(format!("{stem}.{ext}"))).map_err(|e| e.to_string())?;
    Ok(written)
}

fn run<R: Runtime>(app: &AppHandle<R>, dir: &Path, job: &Job, stop: &AtomicBool) -> Result<(), String> {
    let pages_dir = dir.join("p");
    fs::create_dir_all(&pages_dir).map_err(|e| e.to_string())?;
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(300))
        .build();
    let base = job.base.trim_end_matches('/');
    let total = if job.file { 1 } else { job.pages };
    let done = AtomicU32::new(0);
    let bytes = AtomicU64::new(0);
    let emit = |error: Option<String>, finished: bool| {
        let _ = app.emit("offline-progress", Progress {
            id: job.id, done: done.load(Ordering::SeqCst), total, bytes: bytes.load(Ordering::SeqCst),
            error, finished, cancelled: false,
        });
    };
    emit(None, false);

    if find(dir, "cover").is_none() {
        if let Ok(r) = fetch(&agent, &format!("{base}/api/items/{}/cover", job.id), &job.authorization) {
            let _ = save(r, dir, "cover");
        }
    }

    if job.file {
        if find(dir, "file").is_none() {
            let r = fetch(&agent, &format!("{base}/api/items/{}/file", job.id), &job.authorization)?;
            bytes.fetch_add(save(r, dir, "file")?, Ordering::SeqCst);
        }
        done.store(1, Ordering::SeqCst);
    } else {
        let next = AtomicU32::new(0);
        let failed: Mutex<Option<String>> = Mutex::new(None);
        thread::scope(|scope| {
            for _ in 0..WORKERS {
                scope.spawn(|| loop {
                    if stop.load(Ordering::SeqCst) || failed.lock().unwrap().is_some() {
                        return;
                    }
                    let n = next.fetch_add(1, Ordering::SeqCst);
                    if n >= job.pages {
                        return;
                    }
                    let stem = n.to_string();
                    if find(&pages_dir, &stem).is_none() {      // a download cut short resumes where it was
                        let url = format!("{base}/api/items/{}/pages/{n}?w={}", job.id, job.width);
                        match fetch(&agent, &url, &job.authorization).and_then(|r| save(r, &pages_dir, &stem)) {
                            Ok(size) => { bytes.fetch_add(size, Ordering::SeqCst); }
                            Err(e) => {
                                *failed.lock().unwrap() = Some(format!("página {}: {e}", n + 1));
                                return;
                            }
                        }
                    }
                    done.fetch_add(1, Ordering::SeqCst);
                    emit(None, false);
                });
            }
        });
        if let Some(e) = failed.into_inner().unwrap() {
            return Err(e);
        }
    }
    if stop.load(Ordering::SeqCst) {
        return Ok(());
    }
    let meta = serde_json::json!({ "item": job.meta, "width": job.width, "added": now(), "bytes": size_of(dir) });
    fs::write(dir.join("item.json.part"), serde_json::to_vec(&meta).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    fs::rename(dir.join("item.json.part"), dir.join("item.json")).map_err(|e| e.to_string())?;
    emit(None, true);
    Ok(())
}

/// Starts making an item available offline, in the background; progress comes as `offline-progress` events.
#[tauri::command]
pub fn offline_start<R: Runtime>(app: AppHandle<R>, jobs: State<'_, Jobs>, job: Job) -> Result<(), String> {
    let key = format!("{}/{}", clean(&job.account), job.id);
    let dir = item_dir(&app, &job.account, job.id)?;
    let stop = Arc::new(AtomicBool::new(false));
    {
        let mut running = jobs.0.lock().unwrap();
        if running.contains_key(&key) {
            return Ok(());
        }
        running.insert(key.clone(), stop.clone());
    }
    let handle = app.clone();
    thread::spawn(move || {
        let outcome = run(&handle, &dir, &job, &stop);
        handle.state::<Jobs>().0.lock().unwrap().remove(&key);
        if stop.load(Ordering::SeqCst) {
            let _ = fs::remove_dir_all(&dir);
            let _ = handle.emit("offline-progress", Progress {
                id: job.id, done: 0, total: 0, bytes: 0, error: None, finished: false, cancelled: true,
            });
        } else if let Err(e) = outcome {
            let _ = handle.emit("offline-progress", Progress {
                id: job.id, done: 0, total: job.pages.max(1), bytes: 0, error: Some(e), finished: false, cancelled: false,
            });
        }
    });
    Ok(())
}

/// What this account has offline: the item.json of every finished download.
#[tauri::command]
pub fn offline_list<R: Runtime>(app: AppHandle<R>, account: String) -> Result<Vec<serde_json::Value>, String> {
    let dir = root(&app)?.join(clean(&account));
    let Ok(entries) = fs::read_dir(&dir) else { return Ok(vec![]) };
    Ok(entries.flatten()
        .filter_map(|e| fs::read(e.path().join("item.json")).ok())
        .filter_map(|data| serde_json::from_slice(&data).ok())
        .collect())
}

/// Stops a download going on, or deletes a finished one.
#[tauri::command]
pub fn offline_remove<R: Runtime>(app: AppHandle<R>, jobs: State<'_, Jobs>, account: String, id: u64) -> Result<(), String> {
    let key = format!("{}/{}", clean(&account), id);
    if let Some(stop) = jobs.0.lock().unwrap().get(&key) {
        stop.store(true, Ordering::SeqCst);         // the download deletes its folder when it stops
        return Ok(());
    }
    let dir = item_dir(&app, &account, id)?;
    if dir.exists() {
        fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Where the account's downloads are, to show it.
#[tauri::command]
pub fn offline_where<R: Runtime>(app: AppHandle<R>, account: String) -> Result<String, String> {
    Ok(root(&app)?.join(clean(&account)).to_string_lossy().into_owned())
}

/// The `offline` protocol: `/<account>/<id>/cover`, `/file`, `/p/<n>`.
pub fn serve<R: Runtime>(ctx: UriSchemeContext<'_, R>, request: Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    let answer = |status: u16, mime: &str, body: Vec<u8>| {
        Response::builder()
            .status(status)
            .header("Content-Type", mime)
            .header("Access-Control-Allow-Origin", "*")
            .header("Cache-Control", "private, max-age=31536000")
            .body(Cow::Owned(body))
            .unwrap()
    };
    let path = request.uri().path().trim_matches('/').to_string();
    let parts: Vec<&str> = path.split('/').collect();
    let found = (|| {
        let (account, id) = (parts.first()?, parts.get(1)?.parse::<u64>().ok()?);
        let dir = item_dir(ctx.app_handle(), account, id).ok()?;
        match parts.get(2..)? {
            ["cover"] => find(&dir, "cover"),
            ["file"] => find(&dir, "file"),
            ["p", n] if n.chars().all(|c| c.is_ascii_digit()) => find(&dir.join("p"), n),
            _ => None,
        }
    })();
    match found.and_then(|p| fs::read(&p).ok().map(|data| (mime_of(&p), data))) {
        Some((mime, data)) => answer(200, mime, data),
        None => answer(404, "text/plain", b"no descargado".to_vec()),
    }
}
