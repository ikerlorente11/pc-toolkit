//! Reading without connection. A copy kept offline has two parts:
//!
//! - what one reads, in the downloads folder (place.rs), where a person finds it by its name: under the
//!   library's name, at the item's own place in it (`EL archivador/Comics/Avatar/Korra/Korra 01.pdf`). A
//!   book, a comic archive or a PDF of the service's own is the file itself, downloaded whole (nothing to
//!   render on the service: fast); anything else is a folder of its pages as the service renders them
//!   (`…/Korra 01/0.jpg`…);
//! - what only the app needs, in its local data (`offline/<account>/<item id>/`): `item.json` (what the
//!   service said of it, and where its content is), its cover, and pages made from the file: a cbr's or a
//!   cb7's unpacked (reading one page of those means reading all before it), a PDF's rendered as they are
//!   read. `item.json` is written last, so a folder without it is a download still going or cut short.
//!
//! A copy made before there was a content (an older version) has everything in its local data folder
//! (`p/<n>.jpg`, `file.epub`…): it is read just the same.
//! The web view reads them through the `offline` protocol (`http://offline.localhost/<account>/<id>/p/3`
//! on Windows), so the viewer fetches a stored page like any other image, without credentials.

use std::borrow::Cow;
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::http::{Request, Response};
use tauri::{AppHandle, Emitter, Manager, Runtime, State, UriSchemeContext, UriSchemeResponder};

/// Pages asked at once (the service renders them; a Pi has few cores).
const WORKERS: usize = 2;
const ATTEMPTS: u32 = 3;
/// The folder of a library's copies when the page does not name it.
const NO_NAME: &str = "Sin conexión";

/// The downloads going on, by `<account>/<id>`: setting the flag stops one and deletes what it got.
#[derive(Default)]
pub struct Jobs(Mutex<HashMap<String, Arc<AtomicBool>>>);

impl Jobs {
    /// whether a download goes on
    pub fn busy(&self) -> bool {
        !self.0.lock().unwrap().is_empty()
    }
}

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
    /// the library's name as the person calls it: the folder its copies go in
    #[serde(default)]
    library: String,
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

/// Where an item's content is, in the downloads folder (`path`, relative to it, with «/»), and what it is:
/// `file` (a book, served whole), `archive` (a comic archive or a PDF: pages read or rendered from it),
/// `pages` (a folder of the pages as the service rendered them).
#[derive(Serialize, Deserialize, Clone)]
struct Content {
    path: String,
    kind: String,
    #[serde(default)]
    format: String,
}

/// Only letters, digits, `_` and `-`: the account is a folder name and a piece of a URL.
fn clean(account: &str) -> String {
    let out: String = account.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).collect();
    if out.is_empty() { "_".into() } else { out }
}

fn root<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    crate::place::offline_dir(app)
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
        "application/x-mobipocket-ebook" | "application/vnd.amazon.ebook" => "mobi",
        "application/x-fictionbook+xml" => "fb2",
        "application/x-zip-compressed-fb2" => "fbz",
        "text/plain" => "txt",
        "application/pdf" => "pdf",
        "image/vnd.djvu" | "image/x-djvu" => "djvu",
        _ => "bin",
    }
}

fn mime_of(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(|e| e.to_lowercase()).as_deref().unwrap_or("") {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "avif" => "image/avif",
        "bmp" => "image/bmp",
        "epub" => "application/epub+zip",
        "mobi" | "azw" | "azw3" | "prc" => "application/x-mobipocket-ebook",
        "fb2" => "application/x-fictionbook+xml",
        "fbz" => "application/x-zip-compressed-fb2",
        "txt" => "text/plain",
        "pdf" => "application/pdf",
        "djvu" | "djv" => "image/vnd.djvu",
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

/// The size of a file, or of all inside a folder.
fn size_of(path: &Path) -> u64 {
    if path.is_file() {
        return fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    }
    fs::read_dir(path).map(|entries| entries.flatten().map(|e| size_of(&e.path())).sum()).unwrap_or(0)
}

/// A name Windows takes for a file or a folder.
fn safe(name: &str) -> String {
    let out: String = name.chars().map(|c| if c.is_control() || r#"<>:"/\|?*"#.contains(c) { '_' } else { c }).collect();
    let out: String = out.trim().trim_end_matches(['.', ' ']).chars().take(150).collect();
    if out.is_empty() { "_".into() } else { out }
}

/// Where an item's content goes, inside the downloads folder: the library's folder, then the item's own place
/// in it (its folder and file name in the service's reading folder), or for one of an outside library, its
/// series and title.
fn place_of(job: &Job) -> PathBuf {
    let m = &job.meta;
    let text = |key: &str| m.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let mut rel = PathBuf::from(safe(if job.library.trim().is_empty() { NO_NAME } else { job.library.trim() }));
    let own = m.get("source_id").map_or(true, |v| v.is_null());
    if own && !text("name").is_empty() {
        for part in text("folder").split('/').filter(|p| !p.is_empty()) {
            rel.push(safe(part));
        }
        rel.push(safe(&text("name")));
    } else {
        let series = text("series");
        rel.push(safe(if series.is_empty() { "Sueltos" } else { &series }));
        let title = if text("title").is_empty() { job.id.to_string() } else { text("title") };
        let format = text("format");
        rel.push(safe(&if format.is_empty() || format == "folder" { title } else { format!("{title}.{format}") }));
    }
    rel
}

/// The folder a content made of pages goes in: the item's place without its file's extension.
fn pages_place(rel: &Path) -> PathBuf {
    let known = rel.extension().and_then(|e| e.to_str()).is_some_and(|e| {
        matches!(e.to_lowercase().as_str(), "cbz" | "cbr" | "cb7" | "cbt" | "zip" | "rar" | "7z" | "tar" | "pdf" | "djvu" | "djv")
    });
    if known { rel.with_extension("") } else { rel.to_path_buf() }
}

fn rel_text(rel: &Path) -> String {
    rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect::<Vec<_>>().join("/")
}

/// Deletes a content (a file or a folder) of the downloads folder, and the folders it leaves empty.
fn remove_content(downloads: &Path, rel: &Path) {
    let path = downloads.join(rel);
    crate::local::forget_file(&path);
    if path.is_dir() {
        let _ = fs::remove_dir_all(&path);
    } else {
        let _ = fs::remove_file(&path);
    }
    let mut dir = path.parent().map(Path::to_path_buf);
    while let Some(d) = dir {
        if d == downloads || !d.starts_with(downloads) || fs::remove_dir(&d).is_err() {
            break;          // remove_dir only takes an empty folder
        }
        dir = d.parent().map(Path::to_path_buf);
    }
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

/// Downloads a whole file to `target` (written aside first, so a file there is always whole), telling how much
/// came and of how much.
fn download(agent: &ureq::Agent, url: &str, authorization: &str, target: &Path, stop: &AtomicBool,
            progress: impl Fn(u64, Option<u64>)) -> Result<(), String> {
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("no se puede escribir en la carpeta de descargas ({e})"))?;
    }
    let response = fetch(agent, url, authorization)?;
    let length = response.header("Content-Length").and_then(|l| l.parse::<u64>().ok());
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let part = target.with_file_name(format!("{name}.part"));
    let outcome = (|| {
        let mut out = fs::File::create(&part).map_err(|e| e.to_string())?;
        let mut reader = response.into_reader().take(8 << 30);
        let mut buffer = vec![0u8; 1 << 20];
        let (mut received, mut told) = (0u64, 0u64);
        loop {
            if stop.load(Ordering::SeqCst) {
                return Err("parada".to_string());
            }
            let n = reader.read(&mut buffer).map_err(|e| format!("sin conexión ({e})"))?;
            if n == 0 {
                break;
            }
            out.write_all(&buffer[..n]).map_err(|e| e.to_string())?;
            received += n as u64;
            if received - told >= 1 << 20 {
                told = received;
                progress(received, length);
            }
        }
        drop(out);
        if length.is_some_and(|l| l != received) {
            return Err("el archivo llegó a medias".to_string());
        }
        progress(received, length);
        fs::rename(&part, target).map_err(|e| e.to_string())
    })();
    if outcome.is_err() {
        let _ = fs::remove_file(&part);
    }
    outcome
}

/// The format of an item the app can read from its file: a comic archive (cbz, cbr, cb7, cbt) or a PDF of the
/// service's own (not of an outside library).
fn archive_of(meta: &serde_json::Value) -> Option<&'static str> {
    if meta.get("source_id").is_some_and(|s| !s.is_null()) {
        return None;
    }
    match meta.get("format")?.as_str()? {
        "cbz" => Some("cbz"),
        "cbr" => Some("cbr"),
        "cb7" => Some("cb7"),
        "cbt" => Some("cbt"),
        "pdf" => Some("pdf"),
        _ => None,
    }
}

fn run<R: Runtime>(app: &AppHandle<R>, dir: &Path, job: &Job, stop: &AtomicBool) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(300))
        .build();
    let base = job.base.trim_end_matches('/');
    let downloads = crate::place::catalogs_dir(app)?;
    let rel = place_of(job);
    let total = if job.file { 1 } else { job.pages };
    let done = AtomicU32::new(0);
    let bytes = AtomicU64::new(0);
    let emit = |error: Option<String>, finished: bool| {
        let _ = app.emit("offline-progress", Progress {
            id: job.id, done: done.load(Ordering::SeqCst), total, bytes: bytes.load(Ordering::SeqCst),
            error, finished, cancelled: false,
        });
    };
    // while a whole file comes, its share of the pages
    let by_bytes = |received: u64, length: Option<u64>| {
        bytes.store(received, Ordering::SeqCst);
        if let Some(length) = length.filter(|l| *l > 0) {
            let part = ((received as f64 / length as f64) * total as f64) as u32;
            done.store(part.min(total.saturating_sub(1)), Ordering::SeqCst);
        }
        emit(None, false);
    };
    emit(None, false);

    if find(dir, "cover").is_none() {
        if let Ok(r) = fetch(&agent, &format!("{base}/api/items/{}/cover", job.id), &job.authorization) {
            let _ = save(r, dir, "cover");
        }
    }

    let file_url = format!("{base}/api/items/{}/file", job.id);
    let content = if job.file {
        let target = downloads.join(&rel);
        if !target.is_file() {
            download(&agent, &file_url, &job.authorization, &target, stop, &by_bytes)?;
        }
        Content { path: rel_text(&rel), kind: "file".into(), format: String::new() }
    } else if let Some(format) = archive_of(&job.meta) {
        let target = downloads.join(&rel);
        let whole = (|| {
            if !target.is_file() {
                download(&agent, &file_url, &job.authorization, &target, stop, &by_bytes)?;
            }
            if stop.load(Ordering::SeqCst) {
                return Err("parada".to_string());
            }
            let real = crate::local::container(&target, format);
            let count = if real == "cbr" || real == "cb7" {
                crate::local::unpack_pages(&target, &real, &dir.join("p"))?
            } else {
                crate::local::file_page_count(app, &target, &real)?
            };
            if count as u32 != job.pages {
                return Err(format!("tiene {count} páginas y el servicio cuenta {}", job.pages));
            }
            Ok(real)
        })();
        match whole {
            Ok(real) => Content { path: rel_text(&rel), kind: "archive".into(), format: real },
            Err(_) if stop.load(Ordering::SeqCst) => return Ok(()),
            Err(e) => {
                // page by page, as the service renders them
                eprintln!("offline {}: el archivo entero no sirvió ({e}); página a página", job.id);
                remove_content(&downloads, &rel);
                let _ = fs::remove_dir_all(dir.join("p"));
                done.store(0, Ordering::SeqCst);
                bytes.store(0, Ordering::SeqCst);
                let place = pages_place(&rel);
                by_pages(&agent, base, job, &downloads.join(&place), stop, &done, &bytes, &emit)?;
                Content { path: rel_text(&place), kind: "pages".into(), format: String::new() }
            }
        }
    } else {
        let place = pages_place(&rel);
        by_pages(&agent, base, job, &downloads.join(&place), stop, &done, &bytes, &emit)?;
        Content { path: rel_text(&place), kind: "pages".into(), format: String::new() }
    };
    if stop.load(Ordering::SeqCst) {
        return Ok(());
    }
    done.store(total, Ordering::SeqCst);
    let size = size_of(dir) + size_of(&downloads.join(&content.path));
    let meta = serde_json::json!({ "item": job.meta, "width": job.width, "added": now(), "bytes": size, "content": content });
    fs::write(dir.join("item.json.part"), serde_json::to_vec(&meta).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    fs::rename(dir.join("item.json.part"), dir.join("item.json")).map_err(|e| e.to_string())?;
    forget(dir);
    emit(None, true);
    Ok(())
}

/// Page by page, as the service renders them (a few at once), into `pages_dir`, resuming where a download
/// cut short was.
#[allow(clippy::too_many_arguments)]
fn by_pages(agent: &ureq::Agent, base: &str, job: &Job, pages_dir: &Path, stop: &AtomicBool, done: &AtomicU32,
            bytes: &AtomicU64, emit: &(dyn Fn(Option<String>, bool) + Sync)) -> Result<(), String> {
    fs::create_dir_all(pages_dir).map_err(|e| format!("no se puede escribir en la carpeta de descargas ({e})"))?;
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
                if find(pages_dir, &stem).is_none() {
                    let url = format!("{base}/api/items/{}/pages/{n}?w={}", job.id, job.width);
                    match fetch(agent, &url, &job.authorization).and_then(|r| save(r, pages_dir, &stem)) {
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
    match failed.into_inner().unwrap() {
        Some(e) => Err(e),
        None => Ok(()),
    }
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
            // stopped: nothing of it stays (the content too, unless it was there already as a finished copy)
            if !dir.join("item.json").exists() {
                if let Ok(downloads) = crate::place::catalogs_dir(&handle) {
                    let rel = place_of(&job);
                    remove_content(&downloads, &pages_place(&rel));
                    remove_content(&downloads, &rel);
                }
                let _ = fs::remove_dir_all(&dir);
            }
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

/// Stops a download going on, or deletes a finished one (its content in the downloads folder too).
#[tauri::command]
pub fn offline_remove<R: Runtime>(app: AppHandle<R>, jobs: State<'_, Jobs>, account: String, id: u64) -> Result<(), String> {
    let key = format!("{}/{}", clean(&account), id);
    if let Some(stop) = jobs.0.lock().unwrap().get(&key) {
        stop.store(true, Ordering::SeqCst);         // the download deletes what it got when it stops
        return Ok(());
    }
    let dir = item_dir(&app, &account, id)?;
    if let Some(content) = content_of(&dir) {
        remove_content(&crate::place::catalogs_dir(&app)?, Path::new(&content.path));
    }
    forget(&dir);
    if dir.exists() {
        fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Where the downloads are, to show it.
#[tauri::command]
pub fn offline_where<R: Runtime>(app: AppHandle<R>, account: String) -> Result<String, String> {
    let _ = account;
    Ok(crate::place::catalogs_dir(&app)?.to_string_lossy().into_owned())
}

// ---- reading them ----

/// The content of each copy, as its item.json says (read once), by its local data folder.
static CONTENTS: Mutex<Option<HashMap<PathBuf, Option<Content>>>> = Mutex::new(None);

fn content_of(dir: &Path) -> Option<Content> {
    if let Some(known) = CONTENTS.lock().unwrap().get_or_insert_with(HashMap::new).get(dir) {
        return known.clone();
    }
    let content = fs::read(dir.join("item.json")).ok()
        .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
        .and_then(|v| v.get("content").cloned())
        .and_then(|c| serde_json::from_value::<Content>(c).ok());
    CONTENTS.lock().unwrap().get_or_insert_with(HashMap::new).insert(dir.to_path_buf(), content.clone());
    content
}

fn forget(dir: &Path) {
    if let Some(map) = CONTENTS.lock().unwrap().as_mut() {
        map.remove(dir);
    }
}

/// The width a copy's pages were asked in (for a PDF rendered here).
fn width_of(dir: &Path) -> u32 {
    fs::read(dir.join("item.json")).ok()
        .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
        .and_then(|v| v.get("width").and_then(|w| w.as_u64()))
        .map(|w| w as u32)
        .unwrap_or(1600)
}

/// Pages of a PDF being rendered now (by its copy's folder and number), so a read-ahead and a reader asking
/// for the same one do not render it twice.
static RENDERING: Mutex<Option<std::collections::HashSet<(PathBuf, usize)>>> = Mutex::new(None);

/// Page `n` of a kept PDF, rendered once and kept with the copy (`p/<n>.jpg`).
fn render_kept<R: Runtime>(app: &AppHandle<R>, dir: &Path, file: &Path, n: usize) -> Option<Vec<u8>> {
    let kept = dir.join("p").join(format!("{n}.jpg"));
    let key = (dir.to_path_buf(), n);
    loop {
        if let Ok(data) = fs::read(&kept) {
            return Some(data);
        }
        if RENDERING.lock().unwrap().get_or_insert_with(Default::default).insert(key.clone()) {
            break;          // ours to render
        }
        thread::sleep(Duration::from_millis(50));       // another is rendering it: wait for it
    }
    let rendered = crate::local::file_page(app, file, "pdf", n, width_of(dir)).ok().map(|(data, _)| data);
    if let Some(data) = &rendered {
        let _ = fs::create_dir_all(dir.join("p"));
        let part = dir.join("p").join(format!("{n}.jpg.part"));
        if fs::write(&part, data).is_ok() {
            let _ = fs::rename(&part, &kept);
        }
    }
    RENDERING.lock().unwrap().get_or_insert_with(Default::default).remove(&key);
    rendered
}

fn answer<R: Runtime>(app: &AppHandle<R>, request: &Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    let respond = |status: u16, mime: &str, body: Vec<u8>| {
        Response::builder()
            .status(status)
            .header("Content-Type", mime)
            .header("Access-Control-Allow-Origin", "*")
            .header("Cache-Control", if status == 200 { "private, max-age=31536000" } else { "no-store" })
            .body(Cow::Owned(body))
            .unwrap()
    };
    let path = request.uri().path().trim_matches('/').to_string();
    let parts: Vec<&str> = path.split('/').collect();
    let found = (|| -> Option<(Vec<u8>, &'static str)> {
        let (account, id) = (parts.first()?, parts.get(1)?.parse::<u64>().ok()?);
        let dir = item_dir(app, account, id).ok()?;
        let content = content_of(&dir);
        let downloads = crate::place::catalogs_dir(app).ok()?;
        let read = |p: PathBuf| fs::read(&p).ok().map(|data| (data, mime_of(&p)));
        match parts.get(2..)? {
            ["cover"] => read(find(&dir, "cover")?),
            ["file"] => match content.filter(|c| c.kind != "pages") {
                Some(c) => read(downloads.join(&c.path)),
                None => read(find(&dir, "file")?),
            },
            ["p", n] if n.chars().all(|c| c.is_ascii_digit()) => {
                if let Some(p) = find(&dir.join("p"), n) {
                    return read(p);
                }
                let c = content?;
                match c.kind.as_str() {
                    "pages" => read(find(&downloads.join(&c.path), n)?),
                    "archive" => {
                        let (file, n) = (downloads.join(&c.path), n.parse::<usize>().ok()?);
                        if c.format != "pdf" {
                            return crate::local::file_page(app, &file, &c.format, n, width_of(&dir)).ok();
                        }
                        let data = render_kept(app, &dir, &file, n)?;
                        // the next ones too, so turning the page does not wait
                        let (app, dir) = (app.clone(), dir.clone());
                        thread::spawn(move || {
                            for k in n + 1..n + 3 {
                                if find(&dir.join("p"), &k.to_string()).is_none() && render_kept(&app, &dir, &file, k).is_none() {
                                    break;
                                }
                            }
                        });
                        Some((data, "image/jpeg"))
                    }
                    _ => None,
                }
            }
            _ => None,
        }
    })();
    match found {
        Some((data, mime)) => respond(200, mime, data),
        None => respond(404, "text/plain", b"no descargado".to_vec()),
    }
}

/// The `offline` protocol: `/<account>/<id>/cover`, `/file`, `/p/<n>`; answered away from the window's thread
/// (a PDF's page is rendered when first read).
pub fn serve<R: Runtime>(ctx: UriSchemeContext<'_, R>, request: Request<Vec<u8>>, responder: UriSchemeResponder) {
    let app = ctx.app_handle().clone();
    thread::spawn(move || responder.respond(answer(&app, &request)));
}
