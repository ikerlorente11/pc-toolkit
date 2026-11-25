//! The user's cloud (El Archivador: OpenCloud's WebDAV) when the app is connected to a server of El Reproductor:
//! its songs play through the `media` protocol (`/w/<path in the personal space>`), asked for by Rust with the
//! user's app password (an `<audio>` cannot send it) and by ranges, so a song starts at once and seeks anywhere
//! without downloading it whole. The pages list its folders and delete songs (to the cloud's bin) as the web does.
//!
//! Without connection: songs of the cloud can be kept on this PC, copied into the engine's music folder with the
//! cloud's own folders (`/Música/Artistas/…` → `Música\El Reproductor\Artistas\…`). A song with a copy plays from
//! it (no network), and with no network at all the copies are this PC's music.

use std::borrow::Cow;
use std::collections::VecDeque;
use std::fs;
use std::io::Read;
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use tauri::http::{Request, Response};
use tauri::{AppHandle, Emitter, Manager, Runtime, State};

/// A ranged answer is at most this long (the audio element asks again for the rest)…
const RANGE_PIECE: u64 = 4 << 20;
/// …and the first one shorter, so a song starts at once (it is asked for while the listener waits).
const FIRST_PIECE: u64 = 256 << 10;

struct Conn {
    /// the WebDAV root of the personal space (…/remote.php/webdav), without a trailing slash
    webdav: String,
    /// `Basic …` of the user and their app password
    auth: String,
}

#[derive(Default)]
pub struct Cloud(Mutex<Option<Conn>>);

/// One agent for every request: its connections to the cloud stay open between the pieces of a song (a new TLS
/// connection per piece cost most of a second each).
fn agent() -> ureq::Agent {
    static AGENT: std::sync::OnceLock<ureq::Agent> = std::sync::OnceLock::new();
    AGENT
        .get_or_init(|| ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(15)).timeout_read(Duration::from_secs(60)).build())
        .clone()
}

fn basic(user: &str, password: &str) -> String {
    use base64::Engine;
    format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(format!("{user}:{password}")))
}

/// A path of the personal space as a URL path: every segment percent-encoded.
fn encode_path(path: &str) -> String {
    path.split('/')
        .map(|seg| {
            seg.bytes()
                .map(|b| match b {
                    b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
                    _ => format!("%{b:02X}"),
                })
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&text[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn url_of(conn: &Conn, path: &str) -> String {
    format!("{}{}", conn.webdav, encode_path(&format!("/{}", path.trim_start_matches('/'))))
}

/// Connects (or forgets, with no user) the cloud the songs are played from.
#[tauri::command]
pub fn cloud_set(cloud: State<'_, Cloud>, webdav: Option<String>, user: Option<String>, password: Option<String>) {
    *cloud.0.lock().unwrap() = match (webdav, user, password) {
        (Some(w), Some(u), Some(p)) if !w.is_empty() => Some(Conn { webdav: w.trim_end_matches('/').to_string(), auth: basic(&u, &p) }),
        _ => None,
    };
}

#[derive(Serialize, Default)]
pub struct Entry {
    path: String,
    name: String,
    size: u64,
}

#[derive(Serialize, Default)]
pub struct Listing {
    folders: Vec<Entry>,
    files: Vec<Entry>,
}

/// The entries of a PROPFIND answer: (decoded href, is a folder, size).
fn parse_propfind(xml: &str) -> Vec<(String, bool, u64)> {
    use quick_xml::events::Event;
    let mut reader = quick_xml::Reader::from_str(xml);
    let (mut out, mut href, mut folder, mut size, mut field) = (vec![], String::new(), false, 0u64, String::new());
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let name = String::from_utf8_lossy(e.local_name().as_ref()).into_owned();
                if name == "response" {
                    (href, folder, size) = (String::new(), false, 0);
                }
                if name == "collection" {
                    folder = true;
                }
                field = name;
            }
            Ok(Event::Empty(e)) => {
                if e.local_name().as_ref() == b"collection" {
                    folder = true;
                }
            }
            Ok(Event::Text(t)) => {
                let text = t.unescape().map(|c| c.into_owned()).unwrap_or_default();
                match field.as_str() {
                    "href" => href.push_str(&text),
                    "getcontentlength" => size = text.trim().parse().unwrap_or(0),
                    _ => {}
                }
            }
            Ok(Event::End(e)) => {
                if e.local_name().as_ref() == b"response" {
                    out.push((decode(&href), folder, size));
                }
                field.clear();
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    out
}

/// What is right inside a folder of the cloud ("404": not there).
#[tauri::command]
pub async fn cloud_list<R: Runtime>(app: AppHandle<R>, dir: String) -> Result<Listing, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let (url, auth, prefix) = {
            let cloud = app.state::<Cloud>();
            let guard = cloud.0.lock().unwrap();
            let conn = guard.as_ref().ok_or("sin servidor conectado")?;
            // the path part of the WebDAV root, as hrefs start with it
            let prefix = conn.webdav.splitn(4, '/').nth(3).map(|p| format!("/{p}")).unwrap_or_default();
            (url_of(conn, &format!("{}/", dir.trim_end_matches('/'))), conn.auth.clone(), decode(&prefix))
        };
        let body = r#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"#;
        let res = agent().request("PROPFIND", &url).set("Authorization", &auth).set("Depth", "1").send_string(body);
        let text = match res {
            Ok(r) => r.into_string().map_err(|e| e.to_string())?,
            Err(ureq::Error::Status(404, _)) => return Err("404".into()),
            Err(ureq::Error::Status(401, _)) => return Err("la nube no acepta tu contraseña de aplicación".into()),
            Err(e) => return Err(e.to_string()),
        };
        let base = format!("/{}", dir.trim_matches('/'));
        let mut out = Listing::default();
        for (href, folder, size) in parse_propfind(&text).into_iter().skip(1) {
            let rel = href.strip_prefix(&prefix).unwrap_or(&href).trim_end_matches('/').to_string();
            let name = rel.rsplit('/').next().unwrap_or_default().to_string();
            if name.is_empty() {
                continue;
            }
            let entry = Entry { path: format!("{}/{name}", base.trim_end_matches('/')), name, size };
            if folder {
                out.folders.push(entry)
            } else {
                out.files.push(entry)
            }
        }
        Ok(out)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// A song (or a folder) to the cloud's bin ("404": not there).
#[tauri::command]
pub async fn cloud_remove<R: Runtime>(app: AppHandle<R>, path: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let (url, auth) = {
            let cloud = app.state::<Cloud>();
            let guard = cloud.0.lock().unwrap();
            let conn = guard.as_ref().ok_or("sin servidor conectado")?;
            (url_of(conn, &path), conn.auth.clone())
        };
        match agent().delete(&url).set("Authorization", &auth).call() {
            Ok(_) => Ok(()),
            Err(ureq::Error::Status(404, _)) => Err("404".into()),
            Err(e) => Err(e.to_string()),
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

/// `/w/<path>`: a song of the cloud, the piece the audio element asks for (at most RANGE_PIECE), from WebDAV.
pub fn answer<R: Runtime>(app: &AppHandle<R>, path: &str, request: &Request<Vec<u8>>) -> Option<Response<Cow<'static, [u8]>>> {
    // a copy kept on this PC plays from the disk
    if let Some(copy) = crate::engine::music_path(app, &decode(path)).filter(|p| p.is_file()) {
        return crate::library::file_response(&copy, request).ok();
    }
    let (url, auth) = {
        let cloud = app.state::<Cloud>();
        let guard = cloud.0.lock().unwrap();
        let conn = guard.as_ref()?;
        (url_of(conn, &decode(path)), conn.auth.clone())
    };
    // a whole song is asked for as its first piece: the element then knows the size and asks for the rest
    let asked = request.headers().get("range").and_then(|v| v.to_str().ok()).unwrap_or("bytes=0-").to_string();
    let range = limit_range(&asked);
    let res = match agent().get(&url).set("Authorization", &auth).set("Range", &range).call() {
        Ok(r) => r,
        Err(ureq::Error::Status(code, r)) => {
            return Some(Response::builder().status(code).header("Access-Control-Allow-Origin", "*")
                .body(Cow::Owned(r.into_string().unwrap_or_default().into_bytes())).unwrap());
        }
        Err(e) => {
            return Some(Response::builder().status(502).header("Access-Control-Allow-Origin", "*")
                .body(Cow::Owned(e.to_string().into_bytes())).unwrap());
        }
    };
    let status = res.status();
    let mut builder = Response::builder()
        .status(status)
        .header("Accept-Ranges", "bytes")
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Expose-Headers", "Content-Range")
        .header("Cache-Control", "no-store");
    if let Some(v) = res.header("Content-Range") {
        builder = builder.header("Content-Range", v);
    }
    // the cloud says application/octet-stream: the type by the extension, as for this PC's songs
    let kind = crate::library::mime_of(std::path::Path::new(&decode(path)));
    builder = builder.header("Content-Type", if kind == "application/octet-stream" { res.header("Content-Type").unwrap_or(kind) } else { kind });
    let mut body = vec![];
    if res.into_reader().take(RANGE_PIECE + 1).read_to_end(&mut body).is_err() {
        return Some(Response::builder().status(502).body(Cow::Owned(vec![])).unwrap());
    }
    Some(builder.header("Content-Length", body.len()).body(Cow::Owned(body)).unwrap())
}

/// The range to ask the cloud for: what the element asked, cut to RANGE_PIECE bytes.
fn limit_range(asked: &str) -> String {
    let Some(spec) = asked.trim().strip_prefix("bytes=") else { return format!("bytes=0-{}", RANGE_PIECE - 1) };
    let first = spec.split(',').next().unwrap_or("0-");
    let Some((from, to)) = first.split_once('-') else { return format!("bytes=0-{}", RANGE_PIECE - 1) };
    match from.trim().parse::<u64>() {
        Ok(start) => {
            let most = start + if start == 0 { FIRST_PIECE } else { RANGE_PIECE } - 1;
            let end = to.trim().parse::<u64>().map(|e| e.min(most)).unwrap_or(most);
            format!("bytes={start}-{end}")
        }
        Err(_) => format!("bytes={first}"), // `-500`: the end, as it comes
    }
}

// ---- songs of the cloud kept on this PC ----

/// The copies waiting to be made, and how far the queue is (`done` of `total` since it was last empty).
#[derive(Default)]
pub struct Offline {
    queue: Mutex<(VecDeque<String>, usize, usize, bool)>,
}

#[derive(Serialize, Clone)]
struct OfflineProgress {
    done: usize,
    total: usize,
    path: Option<String>,
    error: Option<String>,
}

/// Which of these cloud paths have a copy on this PC.
#[tauri::command]
pub fn offline_have<R: Runtime>(app: AppHandle<R>, paths: Vec<String>) -> Vec<String> {
    paths.into_iter().filter(|p| crate::engine::music_path(&app, p).is_some_and(|f| f.is_file())).collect()
}

/// Puts songs in the queue of copies; one thread makes them one after another.
#[tauri::command]
pub fn offline_get<R: Runtime>(app: AppHandle<R>, offline: State<'_, Offline>, paths: Vec<String>) {
    let start = {
        let mut q = offline.queue.lock().unwrap();
        for p in paths {
            if !q.0.contains(&p) {
                q.0.push_back(p);
                q.2 += 1;
            }
        }
        let start = !q.3;
        q.3 = true;
        start
    };
    if start {
        let app = app.clone();
        std::thread::spawn(move || copy_queue(app));
    }
}

fn copy_queue<R: Runtime>(app: AppHandle<R>) {
    loop {
        let next = {
            let offline = app.state::<Offline>();
            let mut q = offline.queue.lock().unwrap();
            match q.0.pop_front() {
                Some(p) => Some(p),
                None => {
                    *q = (VecDeque::new(), 0, 0, false);
                    None
                }
            }
        };
        let Some(path) = next else { return };
        let error = copy_one(&app, &path).err();
        let (done, total) = {
            let offline = app.state::<Offline>();
            let mut q = offline.queue.lock().unwrap();
            q.1 += 1;
            (q.1, q.2)
        };
        let ok = error.is_none();
        let _ = app.emit("offline-progress", OfflineProgress {
            done, total, path: ok.then(|| path.clone()),
            error: error.map(|e| format!("No se pudo guardar «{}»: {e}", path.rsplit('/').next().unwrap_or(&path))),
        });
    }
}

/// One song from the cloud to its place in the music folder (through a `.part`, so a cut copy is never taken for one).
fn copy_one<R: Runtime>(app: &AppHandle<R>, path: &str) -> Result<(), String> {
    let target = crate::engine::music_path(app, path).ok_or("fuera de la música")?;
    if target.is_file() {
        return Ok(());
    }
    let (url, auth) = {
        let cloud = app.state::<Cloud>();
        let guard = cloud.0.lock().unwrap();
        let conn = guard.as_ref().ok_or("sin servidor conectado")?;
        (url_of(conn, path), conn.auth.clone())
    };
    let res = agent().get(&url).set("Authorization", &auth).timeout(Duration::from_secs(600)).call().map_err(|e| e.to_string())?;
    if let Some(dir) = target.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let part = target.with_extension("part");
    let mut out = fs::File::create(&part).map_err(|e| e.to_string())?;
    let copied = std::io::copy(&mut res.into_reader(), &mut out);
    drop(out);
    if let Err(e) = copied {
        let _ = fs::remove_file(&part);
        return Err(e.to_string());
    }
    fs::rename(&part, &target).map_err(|e| e.to_string())
}

/// Removes the copies (the cloud keeps the songs) and the folders they leave empty (a cover at most).
#[tauri::command]
pub fn offline_remove<R: Runtime>(app: AppHandle<R>, paths: Vec<String>) -> Result<(), String> {
    let root = crate::engine::music_path(&app, "/Música").ok_or("sin carpeta de música")?;
    for p in &paths {
        let Some(file) = crate::engine::music_path(&app, p) else { continue };
        if file.is_file() {
            fs::remove_file(&file).map_err(|e| e.to_string())?;
        }
        // up to the folders right inside the music folder (Artistas stays)
        let mut dir = file.parent().map(|d| d.to_path_buf());
        while let Some(d) = dir {
            if d.parent() == Some(root.as_path()) || d == root {
                break;
            }
            let Ok(entries) = fs::read_dir(&d) else { break };
            let songs = entries.flatten().any(|e| e.path().is_dir() || crate::library::AUDIO.iter().any(|x| e.path().extension().is_some_and(|y| y.eq_ignore_ascii_case(x))));
            if songs || fs::remove_dir_all(&d).is_err() {
                break;
            }
            dir = d.parent().map(|x| x.to_path_buf());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_are_cut() {
        assert_eq!(limit_range("bytes=0-"), format!("bytes=0-{}", FIRST_PIECE - 1));
        assert_eq!(limit_range("bytes=5000-"), format!("bytes=5000-{}", 5000 + RANGE_PIECE - 1));
        assert_eq!(limit_range("bytes=100-199"), "bytes=100-199");
        assert_eq!(limit_range("bytes=-500"), "bytes=-500");
        assert_eq!(limit_range("nada"), format!("bytes=0-{}", RANGE_PIECE - 1));
    }

    #[test]
    fn paths_are_encoded() {
        assert_eq!(encode_path("/Música/AC/DC x (1979)"), "/M%C3%BAsica/AC/DC%20x%20%281979%29");
        assert_eq!(decode(&encode_path("/Música/Artistas/Ñu & Co")), "/Música/Artistas/Ñu & Co");
    }

    #[test]
    fn propfind_is_read() {
        let xml = r#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response><d:href>/remote.php/webdav/M%C3%BAsica/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
          <d:response><d:href>/remote.php/webdav/M%C3%BAsica/Chill/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
          <d:response><d:href>/remote.php/webdav/M%C3%BAsica/a%20b.mp3</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1234</d:getcontentlength></d:prop></d:propstat></d:response>
        </d:multistatus>"#;
        assert_eq!(parse_propfind(xml), vec![
            ("/remote.php/webdav/Música/".to_string(), true, 0),
            ("/remote.php/webdav/Música/Chill/".to_string(), true, 0),
            ("/remote.php/webdav/Música/a b.mp3".to_string(), false, 1234),
        ]);
    }
}
