//! The viewer's network on the desktop (the NetBackend of the shared viewer, see src/lib/net.ts).
//! Requests go through tauri-plugin-http (made by Rust, so no CORS); this module only gives them their
//! User-Agent and downloads files from catalogs (OPDS, MangaDex, Komga, Kavita…) into a folder of the
//! user's Downloads, `La Estantería`, where they stay: the shelf keeps them by their path, so they are
//! not cache, and there the user sees them, moves them or deletes them like any other download.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Runtime, Url};

use crate::local::format_of_name;

/// How often a download says how far it is.
const PROGRESS_EVERY: Duration = Duration::from_millis(150);
/// The longest file name given (Windows allows 255, the folder's path counts too).
const MAX_NAME: usize = 150;

/// What the app says it is to servers, unless the page says otherwise.
pub(crate) fn user_agent() -> String {
    let os = match std::env::consts::OS {
        "windows" => "Windows",
        "macos" => "macOS",
        "linux" => "Linux",
        other => other,
    };
    format!("LaEstanteria/{} ({os})", env!("CARGO_PKG_VERSION"))
}

#[tauri::command]
pub fn net_user_agent() -> String {
    user_agent()
}

/// The folder of catalog downloads: the one chosen in the settings, or `<Downloads>\La Estantería` (see place.rs).
pub fn downloads_dir<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    crate::place::catalogs_dir(app)
}

/// Where catalog downloads go, to show it.
#[tauri::command]
pub fn net_downloads_dir<R: Runtime>(app: AppHandle<R>) -> Result<String, String> {
    Ok(downloads_dir(&app)?.to_string_lossy().into_owned())
}

/// The downloads asked to stop (by the page's mark), until they see it.
static CANCELLED: std::sync::Mutex<Option<std::collections::HashSet<String>>> = std::sync::Mutex::new(None);

fn is_cancelled(id: &str) -> bool {
    !id.is_empty() && CANCELLED.lock().unwrap().as_ref().is_some_and(|set| set.contains(id))
}

/// Stops a download going on (`id`: the mark it was started with); what it got is deleted.
#[tauri::command]
pub fn net_cancel(id: String) {
    CANCELLED.lock().unwrap().get_or_insert_with(Default::default).insert(id);
}

#[derive(Serialize, Clone)]
struct Progress<'a> {
    /// which download (the page's own mark: two downloads of the same address are told apart)
    id: &'a str,
    url: &'a str,
    done: u64,
    /// 0 when the server does not say
    total: u64,
}

/// Downloads `url` into the catalog folder as `name` (made a valid file name, never overwriting:
/// « (2)», « (3)»…) and answers its absolute path, which the shelf's `shelf_add_file` takes.
/// Progress comes as `net-download-progress` events; a download that fails leaves nothing behind.
#[tauri::command]
pub async fn net_download<R: Runtime>(
    app: AppHandle<R>,
    url: String,
    name: String,
    headers: Option<HashMap<String, String>>,
    id: Option<String>,
    folder: Option<String>,
) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let id = id.unwrap_or_default();
        let dir = series_dir(downloads_dir(&app)?, folder.as_deref());
        let got = download(&url, &name, &headers.unwrap_or_default(), &dir, || is_cancelled(&id), |done, total| {
            let _ = app.emit("net-download-progress", Progress { id: &id, url: &url, done, total });
        })
        .map(|path| path.to_string_lossy().into_owned());
        if let Some(set) = CANCELLED.lock().unwrap().as_mut() {
            set.remove(&id);
        }
        got
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Saves a file made in the page (a manga chapter packed as CBZ…) into the catalog folder, with the
/// same names as a download; answers its absolute path. The bytes come as the raw body of the call
/// (no JSON for files of 100 MB), the name and the type in the headers `x-name` and `x-type`
/// (URI-encoded: headers are ASCII).
#[tauri::command]
pub async fn net_save<R: Runtime>(app: AppHandle<R>, request: tauri::ipc::Request<'_>) -> Result<String, String> {
    let tauri::ipc::InvokeBody::Raw(data) = request.body() else {
        return Err("No llegó el archivo que guardar".into());
    };
    let header = |key: &str| request.headers().get(key).and_then(|v| v.to_str().ok()).map(percent_decode).unwrap_or_default();
    let (name, mime, folder) = (header("x-name"), header("x-type"), header("x-folder"));
    let data = data.clone();
    let dir = series_dir(downloads_dir(&app)?, Some(&folder));
    tauri::async_runtime::spawn_blocking(move || save(&dir, &name, &mime, &data).map(|p| p.to_string_lossy().into_owned()))
        .await
        .map_err(|e| e.to_string())?
}

/// «Guardar en el dispositivo»: the system's save dialog, shown here (so the page cannot pick a path
/// itself), and the bytes, the raw body of the call, written where the person chose. The name comes in
/// the header `x-name` (URI-encoded). Answers the path, or nothing when they gave up.
#[tauri::command]
pub async fn net_save_as<R: Runtime>(app: AppHandle<R>, request: tauri::ipc::Request<'_>) -> Result<Option<String>, String> {
    use tauri_plugin_dialog::DialogExt;
    let tauri::ipc::InvokeBody::Raw(data) = request.body() else {
        return Err("No llegó el archivo que guardar".into());
    };
    let name = request.headers().get("x-name").and_then(|v| v.to_str().ok()).map(percent_decode).unwrap_or_default();
    let data = data.clone();
    let mut dialog = app.dialog().file().set_file_name(file_name(&name, None, None, None));
    if let Some(ext) = Path::new(&name).extension().and_then(|e| e.to_str()) {
        dialog = dialog.add_filter(ext.to_uppercase(), &[ext]);
    }
    let (tx, rx) = std::sync::mpsc::channel();
    dialog.save_file(move |chosen| { let _ = tx.send(chosen); });
    let chosen = tauri::async_runtime::spawn_blocking(move || rx.recv().ok().flatten())
        .await
        .map_err(|e| e.to_string())?;
    let Some(path) = chosen.and_then(|p| p.into_path().ok()) else { return Ok(None) };
    tauri::async_runtime::spawn_blocking(move || {
        fs::write(&path, &data).map_err(|e| format!("No se pudo guardar en {} ({e})", path.display()))?;
        Ok(Some(path.to_string_lossy().into_owned()))
    })
    .await
    .map_err(|e| e.to_string())?
}

fn save(dir: &Path, name: &str, mime: &str, data: &[u8]) -> Result<PathBuf, String> {
    let wanted = file_name(name, None, None, Some(mime));
    fs::create_dir_all(dir).map_err(|e| format!("No se pudo crear la carpeta de descargas ({e})"))?;
    let (path, mut file) = create_unique(dir, &wanted).map_err(|e| format!("No se pudo crear el archivo ({e})"))?;
    let written = file.write_all(data).and_then(|_| file.sync_all());
    drop(file);
    if let Err(e) = written {
        let _ = fs::remove_file(&path);
        return Err(format!("No se pudo guardar «{wanted}» ({e})"));
    }
    Ok(path)
}

fn download(
    url: &str,
    name: &str,
    headers: &HashMap<String, String>,
    dir: &Path,
    stop: impl Fn() -> bool,
    progress: impl Fn(u64, u64),
) -> Result<PathBuf, String> {
    let parsed = Url::parse(url).map_err(|_| format!("«{url}» no es una dirección válida"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("Solo se puede descargar de direcciones http o https".into());
    }
    let host = parsed.host_str().unwrap_or("el servidor").to_string();
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(20))
        .timeout_read(Duration::from_secs(120))
        .user_agent(&user_agent())
        // the credentials of a library follow its own redirects, never to another server
        .redirect_auth_headers(ureq::RedirectAuthHeaders::SameHost)
        .build();
    let mut request = agent.get(url);
    for (key, value) in headers {
        request = request.set(key, value);
    }
    let response = match request.call() {
        Ok(r) => r,
        Err(ureq::Error::Status(code, _)) => return Err(format!("No se pudo descargar: {host} respondió {code}")),
        Err(e) => return Err(format!("No se pudo descargar: sin conexión con {host} ({e})")),
    };
    let mime = response.header("Content-Type").unwrap_or("").to_ascii_lowercase();
    if mime.starts_with("text/html") && !name.to_ascii_lowercase().ends_with(".txt") {
        return Err(format!("No se pudo descargar: {host} respondió con una página web, no con un archivo (¿hace falta iniciar sesión?)"));
    }
    let total = response.header("Content-Length").and_then(|v| v.trim().parse::<u64>().ok()).unwrap_or(0);
    let wanted = file_name(
        name,
        response.header("Content-Disposition"),
        parsed.path_segments().and_then(|mut s| s.next_back()).map(percent_decode).as_deref(),
        response.header("Content-Type"),
    );
    fs::create_dir_all(dir).map_err(|e| format!("No se pudo crear la carpeta de descargas ({e})"))?;
    let (path, mut file) = create_unique(dir, &wanted).map_err(|e| format!("No se pudo crear el archivo ({e})"))?;

    let copied = (|| -> io::Result<u64> {
        let mut reader = response.into_reader();
        let mut buffer = vec![0u8; 64 * 1024];
        let mut done = 0u64;
        let mut last = Instant::now();
        progress(0, total);
        loop {
            if stop() {
                return Err(io::Error::other("cancelada"));
            }
            let n = match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            };
            file.write_all(&buffer[..n])?;
            done += n as u64;
            if last.elapsed() >= PROGRESS_EVERY {
                last = Instant::now();
                progress(done, total);
            }
        }
        file.flush()?;
        file.sync_all()?;
        Ok(done)
    })();
    drop(file);
    match copied {
        Ok(done) if total > 0 && done < total => {
            let _ = fs::remove_file(&path);
            Err(format!("La descarga de {host} se cortó ({done} de {total} bytes)"))
        }
        Ok(done) => {
            progress(done, total.max(done));
            Ok(path)
        }
        Err(e) => {
            let _ = fs::remove_file(&path);
            Err(format!("La descarga de {host} se cortó ({e})"))
        }
    }
}

/// Creates `dir/name`, or `dir/<stem> (2).<ext>`, `(3)`… if it is taken, without ever overwriting.
/// The folder of a series inside the downloads' one (one level, its name cleaned); the downloads' own without one.
fn series_dir(dir: PathBuf, series: Option<&str>) -> PathBuf {
    let clean = series.map(sanitize).map(|s| s.trim_matches(|c: char| c == '.' || c.is_whitespace()).to_string()).unwrap_or_default();
    if clean.is_empty() { dir } else { dir.join(clean) }
}

fn create_unique(dir: &Path, name: &str) -> io::Result<(PathBuf, File)> {
    let (stem, ext) = split_extension(name);
    for n in 1..10_000u32 {
        let candidate = if n == 1 { name.to_string() } else { format!("{stem} ({n}){ext}") };
        let path = dir.join(&candidate);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "demasiados archivos con ese nombre"))
}

/// `name` as `(stem, ".ext")`: the extension is the last short run after a dot (`.fb2.zip` as one).
fn split_extension(name: &str) -> (&str, &str) {
    let at = name.len().saturating_sub(8);
    if at > 0 && name.get(at..).is_some_and(|tail| tail.eq_ignore_ascii_case(".fb2.zip")) {
        return (&name[..at], &name[at..]);
    }
    match name.rfind('.') {
        Some(at) if at > 0 && (2..=6).contains(&(name.len() - at)) && name[at + 1..].bytes().all(|b| b.is_ascii_alphanumeric()) => {
            (&name[..at], &name[at..])
        }
        _ => (name, ""),
    }
}

/// The file name to save as: the page's `name`, made valid on Windows; when it has no extension the
/// shelf opens, the one of the server's file name (Content-Disposition, then the address) or of the
/// Content-Type is added, so the shelf can take it.
fn file_name(name: &str, disposition: Option<&str>, url_last: Option<&str>, mime: Option<&str>) -> String {
    let from_server = disposition.and_then(disposition_name).or_else(|| url_last.map(String::from));
    let mut out = sanitize(name);
    if out.is_empty() {
        out = from_server.as_deref().map(sanitize).filter(|s| !s.is_empty()).unwrap_or_else(|| "descarga".into());
    }
    if format_of_name(&out).is_none() {
        let ext = from_server
            .as_deref()
            .filter(|s| format_of_name(s).is_some())
            .map(|s| split_extension(s).1.to_lowercase())
            .filter(|e| !e.is_empty())
            .or_else(|| mime.and_then(extension_of_mime).map(|e| format!(".{e}")));
        if let Some(ext) = ext {
            out.push_str(&ext);
        }
    }
    shorten(&out)
}

/// A name Windows takes: no path separators nor `<>:"|?*`, no control characters, no trailing dots or
/// spaces, not a device name (CON, NUL, COM1…).
fn sanitize(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for c in name.chars() {
        match c {
            ':' => out.push_str(" -"),                 // «Batman: Año uno» → «Batman - Año uno»
            '/' | '\\' | '|' => out.push('-'),
            '"' => out.push('\''),
            '<' | '>' | '?' | '*' => {}
            c if c.is_control() => out.push(' '),
            c => out.push(c),
        }
    }
    let collapsed = out.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out = collapsed.trim_matches(|c: char| c == '.' || c == ' ').to_string();
    let stem = split_extension(&out).0.trim_end().to_uppercase();
    let device = matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (stem.len() == 4 && (stem.starts_with("COM") || stem.starts_with("LPT")) && stem.as_bytes()[3].is_ascii_digit());
    if device {
        out.insert(0, '_');
    }
    out
}

/// At most MAX_NAME characters, cutting the stem and keeping the extension.
fn shorten(name: &str) -> String {
    if name.chars().count() <= MAX_NAME {
        return name.to_string();
    }
    let (stem, ext) = split_extension(name);
    let keep = MAX_NAME.saturating_sub(ext.chars().count());
    let stem: String = stem.chars().take(keep).collect();
    format!("{}{ext}", stem.trim_end_matches(|c: char| c == '.' || c == ' '))
}

/// The file name of a Content-Disposition (`filename*=UTF-8''…` first, then `filename="…"`).
fn disposition_name(header: &str) -> Option<String> {
    let mut plain = None;
    for part in header.split(';').map(str::trim) {
        let Some((key, value)) = part.split_once('=') else { continue };
        let value = value.trim();
        match key.trim().to_ascii_lowercase().as_str() {
            "filename*" => {
                let encoded = value.splitn(3, '\'').nth(2).unwrap_or(value);
                let name = percent_decode(encoded.trim_matches('"'));
                if !name.is_empty() {
                    return Some(name);
                }
            }
            "filename" => plain = Some(value.trim_matches('"').to_string()).filter(|s| !s.is_empty()),
            _ => {}
        }
    }
    plain
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = |b: u8| (b as char).to_digit(16);
            if let (Some(high), Some(low)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push((high * 16 + low) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The extension the shelf opens for a Content-Type, if any.
fn extension_of_mime(mime: &str) -> Option<&'static str> {
    Some(match mime.split(';').next()?.trim().to_ascii_lowercase().as_str() {
        "application/epub+zip" => "epub",
        "application/pdf" => "pdf",
        "application/x-mobipocket-ebook" | "application/vnd.amazon.ebook" | "application/x-mobi8-ebook" => "mobi",
        "application/x-fictionbook+xml" | "application/x-fictionbook" => "fb2",
        "application/x-zip-compressed-fb2" => "fbz",
        "image/vnd.djvu" | "image/x-djvu" => "djvu",
        "text/plain" => "txt",
        "application/vnd.comicbook+zip" | "application/x-cbz" | "application/zip" | "application/x-zip-compressed" => "cbz",
        "application/vnd.comicbook-rar" | "application/x-cbr" | "application/vnd.rar" | "application/x-rar-compressed" => "cbr",
        "application/x-cb7" | "application/x-7z-compressed" => "cb7",
        "application/x-cbt" | "application/x-tar" => "cbt",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_made_valid() {
        assert_eq!(sanitize("Batman: Año uno.cbz"), "Batman - Año uno.cbz");
        assert_eq!(sanitize("..\\..\\Windows/system32.epub"), "-..-Windows-system32.epub");
        assert_eq!(sanitize("¿Qué? <sí> \"no\" | *x*.pdf"), "¿Qué sí 'no' - x.pdf");
        assert_eq!(sanitize("  dos   espacios\t.\n.epub. . "), "dos espacios . .epub");
        assert_eq!(sanitize("con.txt"), "_con.txt");
        assert_eq!(sanitize("COM1"), "_COM1");
        assert_eq!(sanitize("Console.txt"), "Console.txt");
        assert_eq!(sanitize("..."), "");
    }

    #[test]
    fn extensions_are_kept_or_found() {
        assert_eq!(file_name("Don Quijote.epub", None, None, Some("application/octet-stream")), "Don Quijote.epub");
        assert_eq!(file_name("Don Quijote", None, Some("2000.epub.noimages"), Some("application/epub+zip")), "Don Quijote.epub");
        assert_eq!(file_name("Vol. 1", Some("attachment; filename=\"vol1.cbz\""), Some("file"), None), "Vol. 1.cbz");
        assert_eq!(
            file_name("Tomo", Some("attachment; filename=\"x.zip\"; filename*=UTF-8''Tomo%20%C3%BAnico.fb2.zip"), None, None),
            "Tomo.fb2.zip"
        );
        assert_eq!(file_name("", None, Some("Un libro.mobi"), None), "Un libro.mobi");
        assert_eq!(file_name("", None, None, None), "descarga");
        assert_eq!(file_name("Algo", None, Some("download"), Some("text/html")), "Algo");
        let long = format!("{}.epub", "a".repeat(400));
        let short = file_name(&long, None, None, None);
        assert_eq!(short.chars().count(), MAX_NAME);
        assert!(short.ends_with(".epub"));
    }

    #[test]
    fn disposition_names() {
        assert_eq!(disposition_name("attachment; filename=\"a b.cbz\"").as_deref(), Some("a b.cbz"));
        assert_eq!(disposition_name("attachment; filename*=UTF-8''%C3%B1.epub; filename=n.epub").as_deref(), Some("ñ.epub"));
        assert_eq!(disposition_name("inline").as_deref(), None);
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("%zz%4"), "%zz%4");
    }

    #[test]
    fn never_overwrites() {
        let dir = std::env::temp_dir().join(format!("estanteria-net-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let names: Vec<String> = (0..3)
            .map(|_| create_unique(&dir, "Libro.fb2.zip").unwrap().0.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["Libro.fb2.zip", "Libro (2).fb2.zip", "Libro (3).fb2.zip"]);
        let plain = create_unique(&dir, "README").unwrap().0;
        assert!(plain.ends_with("README"));
        assert!(create_unique(&dir, "README").unwrap().0.ends_with("README (2)"));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn saves_files_of_the_page() {
        let dir = std::env::temp_dir().join(format!("estanteria-net-save-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let first = save(&dir, "Capítulo 1: El inicio", "application/vnd.comicbook+zip", b"PK").unwrap();
        assert!(first.ends_with("Capítulo 1 - El inicio.cbz"));
        assert_eq!(fs::read(&first).unwrap(), b"PK");
        let second = save(&dir, "Capítulo 1: El inicio.cbz", "", b"PK").unwrap();
        assert!(second.ends_with("Capítulo 1 - El inicio (2).cbz"));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn only_http() {
        let dir = std::env::temp_dir();
        assert!(download("file:///C:/Windows/win.ini", "x.txt", &HashMap::new(), &dir, || false, |_, _| {}).is_err());
        assert!(download("no es una url", "x.txt", &HashMap::new(), &dir, || false, |_, _| {}).is_err());
    }
}
