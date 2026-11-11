//! The shelf of this computer: folders the user adds as libraries, and files opened one by one (a
//! double click in the Explorer, «Abrir con», a file dropped on the window). Nothing is copied when
//! they are listed; the viewer reads them through the `shelf` protocol:
//!
//! - `/c/<id>`: a small cover (the first page, or the picture a book names, made 400 px wide, kept
//!   in `local-cache/covers/`; a TXT has none);
//! - `/p/<id>/<n>?w=`: a page. A cbz and a cbt are read straight from the archive (a tar is indexed
//!   once and read by offset); a cbr or cb7 is unpacked once into `local-cache/<id>/` (reading one
//!   page of a rar or a 7z means reading all before it), and a PDF page is rendered by PDFium at
//!   the width asked and kept there too. Pages go as they are (AVIF too: WebView2 shows it), but a
//!   JPEG XL one, which WebView2 cannot show, is made JPEG once and kept there. That cache has a
//!   size limit: what was opened longest ago goes first;
//! - `/f/<id>`: the file itself (a book, EPUB, MOBI/AZW3, FB2, FBZ or TXT, that the viewer lays out
//!   itself; a DjVu, that the viewer renders itself; or a PDF for the document reader). A DjVu's
//!   pages never come from here: only its cover (page 1, rendered by djvu-rs).
//!
//! An item's id is `LOCAL_BASE` + a hash of its path, so the same file is the same item (with its
//! progress and notes) every time, and never meets an id of the service (those count from 1).

use std::borrow::Cow;
use std::collections::HashMap;
use std::fs;
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use pdfium_render::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::http::{Request, Response};
use tauri::{AppHandle, Emitter, Manager, Runtime, State, UriSchemeContext, UriSchemeResponder};

/// 2^50: from here on, items are files of this computer (the viewer knows it too, see local.ts).
pub const LOCAL_BASE: u64 = 1 << 50;
const IMAGES: [&str; 8] = ["jpg", "jpeg", "png", "webp", "gif", "avif", "bmp", "jxl"];
const COVER_WIDTH: u32 = 400;
const DEFAULT_CACHE: u64 = 2 << 30;
const UPLOAD_CHUNK: usize = 32 << 20;

// ---- what the user chose: folders and files, kept in local-library.json ----

#[derive(Serialize, Deserialize, Clone)]
pub struct Root {
    id: u32,
    path: String,
    name: String,
}

#[derive(Serialize, Deserialize, Default)]
struct Config {
    #[serde(default)]
    next: u32,
    #[serde(default)]
    roots: Vec<Root>,
    /// files added one by one
    #[serde(default)]
    files: Vec<String>,
    #[serde(default)]
    cache_limit: Option<u64>,
}

/// A file of the shelf, as listed (nothing opened).
#[derive(Serialize, Clone)]
pub struct Listed {
    id: u64,
    /// the root folder it is in (0: a file added on its own)
    root: u32,
    path: String,
    /// its folder inside the root, with «/» («» at the top)
    folder: String,
    name: String,
    format: String,
    size: u64,
    modified: u64,
}

/// What is known of the files listed, by id: where they are (for the protocol).
#[derive(Default)]
pub struct Shelf {
    config: Mutex<Option<Config>>,
    known: Mutex<HashMap<u64, (PathBuf, String)>>,
    /// a cbz's pages (entry names in order), once looked at
    zips: Mutex<HashMap<u64, Vec<String>>>,
    /// a cbt's pages (where each is inside the tar, in order), once looked at
    tars: Mutex<HashMap<u64, Vec<TarPage>>>,
}

/// The file the app was opened with, until the web view asks for it.
#[derive(Default)]
pub struct Launch(pub Mutex<Option<String>>);

/// The first argument that is a file (Windows passes «%1» on a double click).
pub fn file_argument<I: IntoIterator<Item = String>>(args: I) -> Option<String> {
    args.into_iter().skip(1).find(|a| !a.starts_with('-') && Path::new(a).is_file())
}

#[tauri::command]
pub fn local_launch_path(launch: State<'_, Launch>) -> Option<String> {
    launch.0.lock().unwrap().take()
}

/// Brings the window to the front (a second launch of the app, with a file to open).
pub fn focus<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

fn data_dir<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    app.path().app_local_data_dir().map_err(|e| e.to_string())
}

fn cache_dir<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    Ok(data_dir(app)?.join("local-cache"))
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn fnv(data: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in data {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// The id of a file: by its path (the same file keeps its progress after being changed).
pub fn id_of(path: &Path) -> u64 {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let text = canonical.to_string_lossy().trim_start_matches(r"\\?\").to_lowercase();
    LOCAL_BASE + (fnv(text.as_bytes()) & ((1 << 40) - 1))
}

fn clean_path(path: &Path) -> String {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    canonical.to_string_lossy().trim_start_matches(r"\\?\").to_string()
}

fn format_of(path: &Path) -> Option<&'static str> {
    format_of_name(path.file_name()?.to_str()?)
}

/// The format of a file by its name, as the viewer names it (LocalFormat in local.ts).
pub(crate) fn format_of_name(name: &str) -> Option<&'static str> {
    let name = name.to_lowercase();
    if name.ends_with(".fb2.zip") {
        return Some("fbz");             // before the zip of a comic
    }
    match name.rsplit_once('.')?.1 {
        "cbz" | "zip" => Some("cbz"),
        "cbr" | "rar" => Some("cbr"),
        "cb7" | "7z" => Some("cb7"),
        "cbt" | "tar" => Some("cbt"),
        "pdf" => Some("pdf"),
        "djvu" | "djv" => Some("djvu"),
        "epub" => Some("epub"),
        "mobi" | "azw" | "azw3" | "prc" => Some("mobi"),
        "fb2" => Some("fb2"),
        "fbz" => Some("fbz"),
        "txt" => Some("txt"),
        _ => None,
    }
}

/// What a comic archive really is (cbz, cbr, cb7 or cbt), by its first bytes: many a .cbr is a zip
/// inside (and some .cbz a rar), so the extension only says what the user expects. Anything else,
/// or a file that cannot be read, is taken as named.
fn container_of(path: &Path, format: &str) -> String {
    if !matches!(format, "cbz" | "cbr" | "cb7" | "cbt") {
        return format.to_string();
    }
    let mut head = [0u8; 512];
    let mut n = 0;
    if let Ok(mut file) = fs::File::open(path) {
        while n < head.len() {
            match file.read(&mut head[n..]) {
                Ok(0) | Err(_) => break,
                Ok(got) => n += got,
            }
        }
    }
    container_by_head(&head[..n]).unwrap_or(format).to_string()
}

fn container_by_head(head: &[u8]) -> Option<&'static str> {
    if head.starts_with(b"Rar!\x1a\x07") {
        Some("cbr")
    } else if head.starts_with(b"PK\x03\x04") {
        Some("cbz")
    } else if head.starts_with(b"7z\xbc\xaf\x27\x1c") {
        Some("cb7")
    } else if head.get(257..262) == Some(&b"ustar"[..]) {
        Some("cbt")                     // POSIX and GNU tars (an old v7 one is taken as named)
    } else {
        None
    }
}

fn load_config<R: Runtime>(app: &AppHandle<R>, shelf: &Shelf) -> Result<(), String> {
    let mut guard = shelf.config.lock().unwrap();
    if guard.is_none() {
        let file = data_dir(app)?.join("local-library.json");
        let config = fs::read(&file).ok().and_then(|d| serde_json::from_slice::<Config>(&d).ok()).unwrap_or_default();
        *guard = Some(config);
    }
    Ok(())
}

fn with_config<R: Runtime, T>(app: &AppHandle<R>, shelf: &Shelf, change: impl FnOnce(&mut Config) -> T) -> Result<T, String> {
    load_config(app, shelf)?;
    let mut guard = shelf.config.lock().unwrap();
    let config = guard.as_mut().unwrap();
    let out = change(config);
    let dir = data_dir(app)?;
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let tmp = dir.join("local-library.json.part");
    fs::write(&tmp, serde_json::to_vec_pretty(&*config).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    fs::rename(&tmp, dir.join("local-library.json")).map_err(|e| e.to_string())?;
    Ok(out)
}

#[derive(Serialize)]
pub struct ShelfConfig {
    roots: Vec<Root>,
    files: usize,
    cache_limit: u64,
    cache_bytes: u64,
}

#[tauri::command]
pub fn shelf_config<R: Runtime>(app: AppHandle<R>, shelf: State<'_, Shelf>) -> Result<ShelfConfig, String> {
    let (roots, files, limit) = with_config(&app, &shelf, |c| (c.roots.clone(), c.files.len(), c.cache_limit.unwrap_or(DEFAULT_CACHE)))?;
    Ok(ShelfConfig { roots, files, cache_limit: limit, cache_bytes: cache_size(&cache_dir(&app)?) })
}

#[tauri::command]
pub fn shelf_add_root<R: Runtime>(app: AppHandle<R>, shelf: State<'_, Shelf>, path: String) -> Result<Root, String> {
    let dir = PathBuf::from(&path);
    if !dir.is_dir() {
        return Err("esa carpeta no existe".into());
    }
    let path = clean_path(&dir);
    with_config(&app, &shelf, |c| {
        if let Some(found) = c.roots.iter().find(|r| r.path.eq_ignore_ascii_case(&path)) {
            return found.clone();
        }
        c.next = c.next.max(1) + 1;           // 1 is the files added on their own
        let name = Path::new(&path).file_name().and_then(|n| n.to_str()).unwrap_or(&path).to_string();
        let root = Root { id: c.next, path: path.clone(), name };
        c.roots.push(root.clone());
        root
    })
}

#[tauri::command]
pub fn shelf_remove_root<R: Runtime>(app: AppHandle<R>, shelf: State<'_, Shelf>, id: u32) -> Result<(), String> {
    with_config(&app, &shelf, |c| c.roots.retain(|r| r.id != id))
}

#[tauri::command]
pub fn shelf_rename_root<R: Runtime>(app: AppHandle<R>, shelf: State<'_, Shelf>, id: u32, name: String) -> Result<(), String> {
    with_config(&app, &shelf, |c| {
        if let Some(r) = c.roots.iter_mut().find(|r| r.id == id) {
            r.name = name.trim().to_string();
        }
    })
}

/// Adds a file on its own (it shows among «Archivos sueltos»); what it is, listed.
#[tauri::command]
pub fn shelf_add_file<R: Runtime>(app: AppHandle<R>, shelf: State<'_, Shelf>, path: String) -> Result<Listed, String> {
    let file = PathBuf::from(&path);
    let format = format_of(&file).ok_or("La Estantería abre cbz, cbr, cb7, cbt, pdf, djvu, epub, mobi, azw3, fb2, fbz y txt")?;
    let meta = fs::metadata(&file).map_err(|e| format!("no se encuentra el archivo ({e})"))?;
    let path = clean_path(&file);
    // inside a folder of the shelf: it is there already, with its folder
    let roots = with_config(&app, &shelf, |c| c.roots.clone())?;
    for root in &roots {
        if let Ok(rest) = Path::new(&path).strip_prefix(&root.path) {
            return Ok(listed(&shelf, root.id, Path::new(&path), rest.parent().unwrap_or(Path::new("")), format, &meta));
        }
    }
    with_config(&app, &shelf, |c| {
        if !c.files.iter().any(|f| f.eq_ignore_ascii_case(&path)) {
            c.files.push(path.clone());
        }
    })?;
    Ok(listed(&shelf, 1, Path::new(&path), Path::new(""), format, &meta))
}

#[tauri::command]
pub fn shelf_remove_file<R: Runtime>(app: AppHandle<R>, shelf: State<'_, Shelf>, id: u64) -> Result<(), String> {
    with_config(&app, &shelf, |c| c.files.retain(|f| id_of(Path::new(f)) != id))?;
    let _ = fs::remove_dir_all(cache_dir(&app)?.join(id.to_string()));
    Ok(())
}

fn listed(shelf: &Shelf, root: u32, path: &Path, folder: &Path, format: &str, meta: &fs::Metadata) -> Listed {
    let id = id_of(path);
    shelf.known.lock().unwrap().insert(id, (path.to_path_buf(), format.to_string()));
    let modified = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    Listed {
        id, root, path: path.to_string_lossy().into_owned(),
        folder: folder.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect::<Vec<_>>().join("/"),
        name: path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string(),
        format: format.to_string(), size: meta.len(), modified,
    }
}

fn walk(shelf: &Shelf, root: &Root, dir: &Path, depth: u32, out: &mut Vec<Listed>) {
    if depth > 24 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name.starts_with('$') || name.eq_ignore_ascii_case("System Volume Information") {
            continue;
        }
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            walk(shelf, root, &path, depth + 1, out);
        } else if let Some(format) = format_of(&path) {
            if let Ok(meta) = entry.metadata() {
                let rest = path.strip_prefix(&root.path).map(|p| p.parent().unwrap_or(Path::new("")).to_path_buf()).unwrap_or_default();
                out.push(listed(shelf, root.id, &path, &rest, format, &meta));
            }
        }
    }
}

/// Everything on the shelf now: the files of every folder (and their subfolders) and those added alone.
#[tauri::command]
pub async fn shelf_scan<R: Runtime>(app: AppHandle<R>) -> Result<Vec<Listed>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let shelf = app.state::<Shelf>();
        let (roots, files) = with_config(&app, &shelf, |c| (c.roots.clone(), c.files.clone()))?;
        let mut out = vec![];
        for root in &roots {
            walk(&shelf, root, Path::new(&root.path), 0, &mut out);
        }
        for file in files {
            let path = PathBuf::from(&file);
            if let (Some(format), Ok(meta)) = (format_of(&path), fs::metadata(&path)) {
                if !out.iter().any(|l| l.id == id_of(&path)) {
                    out.push(listed(&shelf, 1, &path, Path::new(""), format, &meta));
                }
            }
        }
        Ok(out)
    }).await.map_err(|e| e.to_string())?
}

// ---- reading the archives ----

/// Compares names as people do: «2.jpg» before «10.jpg».
fn natural(a: &str, b: &str) -> std::cmp::Ordering {
    fn chunks(s: &str) -> Vec<(bool, String)> {
        let mut out: Vec<(bool, String)> = vec![];
        for c in s.to_lowercase().chars() {
            let digit = c.is_ascii_digit();
            match out.last_mut() {
                Some((d, text)) if *d == digit => text.push(c),
                _ => out.push((digit, c.to_string())),
            }
        }
        out
    }
    let (x, y) = (chunks(a), chunks(b));
    for (p, q) in x.iter().zip(y.iter()) {
        let order = match (p.0, q.0) {
            (true, true) => {
                let (m, n) = (p.1.trim_start_matches('0'), q.1.trim_start_matches('0'));
                m.len().cmp(&n.len()).then_with(|| m.cmp(n))
            }
            _ => p.1.cmp(&q.1),
        };
        if order != std::cmp::Ordering::Equal {
            return order;
        }
    }
    x.len().cmp(&y.len())
}

fn image_ext(name: &str) -> Option<String> {
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    if base.starts_with('.') || name.contains("__MACOSX") {
        return None;
    }
    let ext = Path::new(base).extension()?.to_str()?.to_lowercase();
    IMAGES.contains(&ext.as_str()).then(|| if ext == "jpeg" { "jpg".into() } else { ext })
}

fn mime_of(ext: &str) -> &'static str {
    match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "avif" => "image/avif",
        "bmp" => "image/bmp",
        "jxl" => "image/jxl",
        "epub" => "application/epub+zip",
        "mobi" => "application/x-mobipocket-ebook",
        "fb2" => "application/x-fictionbook+xml",
        "fbz" => "application/x-zip-compressed-fb2",
        "txt" => "text/plain",
        "pdf" => "application/pdf",
        "djvu" => "image/vnd.djvu",
        _ => "application/octet-stream",
    }
}

fn open_zip(path: &Path) -> Result<zip::ZipArchive<fs::File>, String> {
    zip::ZipArchive::new(fs::File::open(path).map_err(|e| e.to_string())?).map_err(|e| format!("no es un zip válido ({e})"))
}

fn zip_pages(path: &Path) -> Result<Vec<String>, String> {
    let zip = open_zip(path)?;
    let mut names: Vec<String> = zip.file_names().filter(|n| !n.ends_with('/') && image_ext(n).is_some()).map(String::from).collect();
    names.sort_by(|a, b| natural(a, b));
    Ok(names)
}

fn zip_read(path: &Path, name: &str, limit: Option<u64>) -> Result<Vec<u8>, String> {
    let mut zip = open_zip(path)?;
    let entry = zip.by_name(name).map_err(|e| e.to_string())?;
    let mut data = vec![];
    match limit {
        Some(n) => entry.take(n).read_to_end(&mut data),
        None => { let mut e = entry; e.read_to_end(&mut data) }
    }.map_err(|e| e.to_string())?;
    Ok(data)
}

/// An image of a tar: its name and where its bytes are (a tar stores them whole, one after another).
#[derive(Clone, Debug, PartialEq)]
struct TarPage {
    name: String,
    offset: u64,
    size: u64,
}

/// The images of a tar, in the order of their names: only the headers are read (the data is skipped).
fn tar_index<R: Read + Seek>(reader: R) -> Result<Vec<TarPage>, String> {
    let bad = |e: io::Error| format!("no es un tar válido ({e})");
    let mut archive = tar::Archive::new(reader);
    let mut pages = vec![];
    for entry in archive.entries_with_seek().map_err(bad)? {
        let entry = entry.map_err(bad)?;
        if !entry.header().entry_type().is_file() {
            continue;
        }
        let name = String::from_utf8_lossy(&entry.path_bytes()).into_owned();
        if image_ext(&name).is_some() {
            pages.push(TarPage { name, offset: entry.raw_file_position(), size: entry.size() });
        }
    }
    pages.sort_by(|a, b| natural(&a.name, &b.name));
    Ok(pages)
}

fn tar_pages(path: &Path) -> Result<Vec<TarPage>, String> {
    tar_index(BufReader::new(fs::File::open(path).map_err(|e| e.to_string())?))
}

fn tar_read(path: &Path, page: &TarPage, limit: Option<u64>) -> Result<Vec<u8>, String> {
    let mut file = fs::File::open(path).map_err(|e| e.to_string())?;
    file.seek(SeekFrom::Start(page.offset)).map_err(|e| e.to_string())?;
    let mut data = vec![];
    file.take(limit.unwrap_or(page.size).min(page.size)).read_to_end(&mut data).map_err(|e| e.to_string())?;
    Ok(data)
}

/// Unpacks the images of a cbr or cb7 into `dir/p/<n>.<ext>` (in the order of their names).
fn unpack(path: &Path, format: &str, dir: &Path) -> Result<usize, String> {
    let pages = dir.join("p");
    let _ = fs::remove_dir_all(dir);
    fs::create_dir_all(&pages).map_err(|e| e.to_string())?;
    let mut names: Vec<(String, String, PathBuf)> = vec![];
    let mut keep = |name: &str, reader: &mut dyn Read| -> Result<(), String> {
        let Some(ext) = image_ext(name) else { return Ok(()) };
        let tmp = pages.join(format!("x{}.part", names.len()));
        let mut out = fs::File::create(&tmp).map_err(|e| e.to_string())?;
        io::copy(reader, &mut out).map_err(|e| e.to_string())?;
        names.push((name.to_string(), ext, tmp));
        Ok(())
    };
    let outcome = if format == "cb7" {
        let mut failed: Option<String> = None;
        sevenz_rust::SevenZReader::open(path, sevenz_rust::Password::empty())
            .map_err(|e| format!("no es un 7z válido ({e})"))?
            .for_each_entries(|entry, reader| {
                if !entry.is_directory() {
                    if image_ext(entry.name()).is_some() {
                        if let Err(e) = keep(entry.name(), reader) {
                            failed = Some(e);
                            return Ok(false);
                        }
                    } else {
                        io::copy(reader, &mut io::sink())?;
                    }
                }
                Ok(true)
            })
            .map_err(|e| e.to_string())
            .and_then(|_| failed.map_or(Ok(()), Err))
    } else {
        (|| {
            let mut archive = unrar::Archive::new(path).open_for_processing().map_err(|e| format!("no es un rar válido ({e})"))?;
            while let Some(header) = archive.read_header().map_err(|e| e.to_string())? {
                let name = header.entry().filename.to_string_lossy().into_owned();
                archive = if header.entry().is_file() && image_ext(&name).is_some() {
                    let (data, rest) = header.read().map_err(|e| e.to_string())?;
                    keep(&name, &mut data.as_slice())?;
                    rest
                } else {
                    header.skip().map_err(|e| e.to_string())?
                };
            }
            Ok(())
        })()
    };
    outcome?;
    if names.is_empty() {
        return Err("no tiene imágenes".into());
    }
    names.sort_by(|a, b| natural(&a.0, &b.0));
    for (n, (_, ext, tmp)) in names.iter().enumerate() {
        fs::rename(tmp, pages.join(format!("{n}.{ext}"))).map_err(|e| e.to_string())?;
    }
    Ok(names.len())
}

/// The file of `dir` whose name, without its extension, is `stem`.
fn find(dir: &Path, stem: &str) -> Option<PathBuf> {
    fs::read_dir(dir).ok()?.flatten().map(|e| e.path()).find(|p| {
        p.is_file() && p.file_stem().and_then(|s| s.to_str()) == Some(stem) && p.extension().map(|e| e != "part").unwrap_or(true)
    })
}

// ---- PDFium ----

static PDFIUM: OnceLock<Result<Pdfium, String>> = OnceLock::new();

/// PDFium, loaded once from the app's folder (the installer puts pdfium.dll next to the exe).
fn pdfium<R: Runtime>(app: &AppHandle<R>) -> Result<&'static Pdfium, String> {
    PDFIUM.get_or_init(|| {
        let mut places: Vec<PathBuf> = vec![];
        if let Ok(dir) = app.path().resource_dir() {
            places.push(dir.clone());
            places.push(dir.join("pdfium"));
        }
        if let Some(dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)) {
            places.push(dir.clone());
            places.push(dir.join("pdfium"));
        }
        places.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("pdfium"));     // while developing
        for place in places {
            if let Ok(bindings) = Pdfium::bind_to_library(Pdfium::pdfium_platform_library_name_at_path(&place)) {
                return Ok(Pdfium::new(bindings));
            }
        }
        Err("falta PDFium (pdfium.dll); reinstala La Estantería".into())
    }).as_ref().map_err(|e| e.clone())
}

fn pdf_info(pdfium: &Pdfium, path: &Path) -> Result<(usize, Vec<[u32; 2]>), String> {
    let doc = pdfium.load_pdf_from_file(path, None).map_err(|e| format!("no se puede abrir el PDF ({e})"))?;
    let pages = doc.pages();
    let sizes: Vec<[u32; 2]> = pages.iter().map(|p| [(p.width().value * 2.0) as u32, (p.height().value * 2.0) as u32]).collect();
    Ok((pages.len() as usize, sizes))
}

fn pdf_render(pdfium: &Pdfium, path: &Path, n: usize, width: u32) -> Result<Vec<u8>, String> {
    let doc = pdfium.load_pdf_from_file(path, None).map_err(|e| format!("no se puede abrir el PDF ({e})"))?;
    let page = doc.pages().get(n as u16).map_err(|_| "esa página no existe".to_string())?;
    let config = PdfRenderConfig::new().set_target_width(width as i32).set_maximum_height((width * 4) as i32);
    let bitmap = page.render_with_config(&config).map_err(|e| e.to_string())?;
    let (w, h) = (bitmap.width() as u32, bitmap.height() as u32);
    let rgba = image::RgbaImage::from_raw(w, h, bitmap.as_rgba_bytes()).ok_or("PDFium dio una imagen rara")?;
    jpeg(&image::DynamicImage::ImageRgba8(rgba), 85)
}

/// The first page of a DjVu, `width` wide, as a JPEG (djvu-rs, pure Rust). A damaged chunk does
/// not stop it: what could be read is drawn.
fn djvu_render(data: &[u8], width: u32) -> Result<Vec<u8>, String> {
    use djvu_rs::djvu_render::{render_pixmap, RenderOptions};
    let doc = djvu_rs::DjVuDocument::parse(data).map_err(|e| format!("no se puede abrir el DjVu ({e})"))?;
    let page = doc.page(0).map_err(|e| format!("no se puede abrir el DjVu ({e})"))?;
    let mut options = RenderOptions::fit_to_width(page, width);
    options.permissive = true;
    let pixmap = render_pixmap(page, &options).map_err(|e| e.to_string())?;
    let rgba = image::RgbaImage::from_raw(pixmap.width, pixmap.height, pixmap.data).ok_or("djvu-rs dio una imagen rara")?;
    jpeg(&image::DynamicImage::ImageRgba8(rgba), 85)
}

fn jpeg(img: &image::DynamicImage, quality: u8) -> Result<Vec<u8>, String> {
    let mut out = vec![];
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality)
        .encode_image(&img.to_rgb8())
        .map_err(|e| e.to_string())?;
    Ok(out)
}

fn is_jxl(data: &[u8]) -> bool {
    data.starts_with(&[0xff, 0x0a]) || data.starts_with(b"\0\0\0\x0cJXL \r\n\x87\n")
}

fn is_avif(data: &[u8]) -> bool {
    data.get(4..8) == Some(&b"ftyp"[..]) && matches!(data.get(8..12), Some(b"avif") | Some(b"avis"))
}

/// A picture as pixels: what the image crate reads, and JPEG XL (with jxl-oxide). AVIF is not
/// read (its decoder, dav1d, is C): where it is shown as it is, WebView2 shows it.
fn decode(data: &[u8]) -> Result<image::DynamicImage, String> {
    if is_jxl(data) {
        let decoder = jxl_oxide::integration::JxlDecoder::new(io::Cursor::new(data)).map_err(|e| e.to_string())?;
        return image::DynamicImage::from_decoder(decoder).map_err(|e| e.to_string());
    }
    image::load_from_memory(data).map_err(|e| e.to_string())
}

fn small(data: &[u8]) -> Result<Vec<u8>, String> {
    let img = decode(data)?;
    let img = if img.width() > COVER_WIDTH { img.resize(COVER_WIDTH, COVER_WIDTH * 4, image::imageops::FilterType::Triangle) } else { img };
    jpeg(&img, 82)
}

/// The cover image of an EPUB: the one its package names, or the first called «cover», or none.
fn epub_cover(path: &Path) -> Option<Vec<u8>> {
    let mut zip = open_zip(path).ok()?;
    let names: Vec<String> = zip.file_names().map(String::from).collect();
    let opf = names.iter().find(|n| n.to_lowercase().ends_with(".opf"))?.clone();
    let mut text = String::new();
    zip.by_name(&opf).ok()?.read_to_string(&mut text).ok()?;
    let base = opf.rsplit_once('/').map(|(b, _)| format!("{b}/")).unwrap_or_default();
    let attr = |tag: &str, key: &str| -> Option<String> {
        let at = tag.find(&format!("{key}=\""))? + key.len() + 2;
        Some(tag[at..].split('"').next()?.to_string())
    };
    let tags: Vec<&str> = text.split('<').collect();
    let cover_id = tags.iter().find(|t| t.starts_with("meta") && t.contains("name=\"cover\"")).and_then(|t| attr(t, "content"));
    let href = tags.iter().filter(|t| t.starts_with("item ") || t.starts_with("item\t"))
        .find(|t| t.contains("cover-image") || cover_id.as_deref().is_some_and(|id| attr(t, "id").as_deref() == Some(id)))
        .and_then(|t| attr(t, "href"))
        .map(|h| format!("{base}{h}"))
        .or_else(|| names.iter().find(|n| n.to_lowercase().contains("cover") && image_ext(n).is_some()).cloned())?;
    let mut data = vec![];
    zip.by_name(&href).ok()?.read_to_end(&mut data).ok()?;
    Some(data)
}

/// A JPEG, PNG, GIF or BMP, by its first bytes (the pictures a MOBI keeps).
fn is_picture(data: &[u8]) -> bool {
    data.starts_with(&[0xff, 0xd8]) || data.starts_with(b"\x89PNG") || data.starts_with(b"GIF8") || data.starts_with(b"BM")
}

/// The cover of a MOBI, AZW or AZW3, a PalmDB of records: the record EXTH 201 names (counted from
/// the first image the MOBI header names), else EXTH 202 (the thumbnail), else the first picture.
/// Only the header, the first record and the pictures looked at are read.
fn mobi_cover<R: Read + Seek>(r: &mut R) -> Option<Vec<u8>> {
    let mut head = [0u8; 78];
    r.read_exact(&mut head).ok()?;
    if &head[60..68] != b"BOOKMOBI" {
        return None;
    }
    let count = u16::from_be_bytes([head[76], head[77]]) as usize;
    let mut table = vec![0u8; count * 8];
    r.read_exact(&mut table).ok()?;
    let starts: Vec<u64> = table.chunks(8).map(|c| u32::from_be_bytes([c[0], c[1], c[2], c[3]]) as u64).collect();
    let end = r.seek(SeekFrom::End(0)).ok()?;
    let mut record = |i: usize, limit: u64| -> Option<Vec<u8>> {
        let start = *starts.get(i)?;
        let stop = starts.get(i + 1).copied().unwrap_or(end).min(end);
        if stop <= start {
            return None;
        }
        r.seek(SeekFrom::Start(start)).ok()?;
        let mut data = vec![];
        r.by_ref().take((stop - start).min(limit)).read_to_end(&mut data).ok()?;
        Some(data)
    };
    let be32 = |d: &[u8], at: usize| d.get(at..at + 4).map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]));

    // record 0: the PalmDOC header (16 bytes), the MOBI header, then EXTH
    let first = record(0, 1 << 20)?;
    if first.get(16..20)? != b"MOBI" {
        return None;
    }
    let header_len = be32(&first, 20)? as usize;
    let first_image = be32(&first, 108).filter(|&n| n != u32::MAX && header_len >= 96)? as usize;
    let mut named: Vec<(u32, u32)> = vec![];
    let exth = 16 + header_len;
    if first.get(exth..exth + 4) == Some(&b"EXTH"[..]) {
        let mut at = exth + 12;
        for _ in 0..be32(&first, exth + 8).unwrap_or(0) {
            let (Some(kind), Some(len)) = (be32(&first, at), be32(&first, at + 4)) else { break };
            if len < 8 {
                break;
            }
            if matches!(kind, 201 | 202) && len >= 12 {
                if let Some(offset) = be32(&first, at + 8).filter(|&o| o != u32::MAX) {
                    named.push((kind, offset));
                }
            }
            at += len as usize;
        }
    }
    named.sort();                       // the cover before the thumbnail
    for (_, offset) in named {
        if let Some(data) = record(first_image + offset as usize, 64 << 20).filter(|d| is_picture(d)) {
            return Some(data);
        }
    }
    for i in first_image..count.min(first_image + 64) {
        if record(i, 8).is_some_and(|d| is_picture(&d)) {
            return record(i, 64 << 20);
        }
    }
    None
}

/// Any bytes as UTF-8, each byte taken as Latin-1: the XML reader wants UTF-8 and many an FB2 is in
/// Windows-1251. Tag names, ids and base64 are ASCII, so they come through the same.
struct Latin1<R> {
    inner: R,
    pending: Option<u8>,
}

impl<R: Read> Read for Latin1<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        if let Some(b) = self.pending.take() {
            buf[0] = b;
            return Ok(1);
        }
        let mut raw = vec![0u8; buf.len().div_ceil(2)];
        let got = self.inner.read(&mut raw)?;
        let mut n = 0;
        for &b in &raw[..got] {
            if b < 0x80 {
                buf[n] = b;
                n += 1;
            } else {
                buf[n] = 0xc0 | (b >> 6);
                n += 1;
                if n < buf.len() {
                    buf[n] = 0x80 | (b & 0x3f);
                    n += 1;
                } else {
                    self.pending = Some(0x80 | (b & 0x3f));
                }
            }
        }
        Ok(n)
    }
}

/// The cover of an FB2: `<coverpage><image l:href="#id"/>` names a `<binary id="id">` in base64
/// (or, with no coverpage, a binary called «cover»). The XML is read as it comes: the binaries are
/// at the end and a book can be big.
fn fb2_cover<R: Read>(input: R) -> Option<Vec<u8>> {
    use base64::Engine;
    use quick_xml::events::{BytesStart, Event};

    let attr = |e: &BytesStart, name: &str| -> Option<String> {
        e.attributes().flatten().find(|a| a.key.local_name().as_ref() == name).map(|a| a.value.trim().to_string())
    };
    let mut reader = quick_xml::Reader::from_reader(BufReader::new(Latin1 { inner: input, pending: None }));
    let config = reader.config_mut();
    config.check_end_names = false;
    config.allow_unmatched_ends = true;
    config.allow_dangling_amp = true;
    let mut buf = vec![];
    let (mut in_coverpage, mut cover_id, mut collecting): (bool, Option<String>, Option<String>) = (false, None, None);
    loop {
        match reader.read_event_into(&mut buf).ok()? {
            Event::Start(e) | Event::Empty(e) if e.local_name().as_ref() == "image" => {
                if in_coverpage && cover_id.is_none() {
                    cover_id = attr(&e, "href").map(|h| h.trim_start_matches('#').to_string());
                }
            }
            Event::Start(e) => match e.local_name().as_ref() {
                "coverpage" => in_coverpage = true,
                "binary" if collecting.is_none() => {
                    let id = attr(&e, "id").unwrap_or_default();
                    let wanted = match &cover_id {
                        Some(cover) => id == *cover,
                        None => id.to_lowercase().contains("cover"),
                    };
                    if wanted {
                        collecting = Some(String::new());
                    }
                }
                _ => {}
            },
            Event::Text(t) => {
                if let Some(text) = collecting.as_mut() {
                    text.extend(t.chars().filter(|c| !c.is_whitespace()));
                }
            }
            Event::End(e) => match e.local_name().as_ref() {
                "coverpage" => in_coverpage = false,
                "binary" => {
                    if let Some(text) = collecting.take() {
                        let lenient = base64::engine::GeneralPurpose::new(&base64::alphabet::STANDARD,
                            base64::engine::GeneralPurposeConfig::new()
                                .with_decode_padding_mode(base64::engine::DecodePaddingMode::Indifferent)
                                .with_decode_allow_trailing_bits(true));
                        return lenient.decode(text.as_bytes()).ok().filter(|d| !d.is_empty());
                    }
                }
                _ => {}
            },
            Event::Eof => return None,
            _ => {}
        }
        buf.clear();
    }
}

/// The cover of an FBZ (a zipped FB2): that of the first .fb2 inside.
fn fbz_cover(path: &Path) -> Option<Vec<u8>> {
    let mut zip = open_zip(path).ok()?;
    let name = zip.file_names().find(|n| n.to_lowercase().ends_with(".fb2"))?.to_string();
    let entry = zip.by_name(&name).ok()?;
    fb2_cover(entry)
}

// ---- the cache of what was opened ----

fn cache_size(dir: &Path) -> u64 {
    fs::read_dir(dir).map(|entries| entries.flatten().map(|e| {
        let p = e.path();
        if p.is_dir() { cache_size(&p) } else { e.metadata().map(|m| m.len()).unwrap_or(0) }
    }).sum()).unwrap_or(0)
}

/// Keeps the cache under its limit: the items opened longest ago go (never `keep`, nor the covers).
fn prune<R: Runtime>(app: &AppHandle<R>, keep: u64) {
    let Ok(dir) = cache_dir(app) else { return };
    let shelf = app.state::<Shelf>();
    let limit = with_config(app, &shelf, |c| c.cache_limit.unwrap_or(DEFAULT_CACHE)).unwrap_or(DEFAULT_CACHE);
    let mut items: Vec<(u64, PathBuf, u64)> = fs::read_dir(&dir).map(|entries| entries.flatten()
        .filter(|e| e.path().is_dir() && e.file_name() != "covers" && e.file_name() != keep.to_string().as_str())
        .map(|e| {
            let used = fs::metadata(e.path().join("used")).and_then(|m| m.modified()).ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
            (used, e.path(), cache_size(&e.path()))
        }).collect()).unwrap_or_default();
    let mut total: u64 = cache_size(&dir);
    items.sort_by_key(|i| i.0);
    for (_, path, size) in items {
        if total <= limit {
            break;
        }
        if fs::remove_dir_all(&path).is_ok() {
            total = total.saturating_sub(size);
        }
    }
}

fn touch(dir: &Path) {
    let _ = fs::write(dir.join("used"), now().to_string());
}

/// The dir of an item in the cache, emptied when the file changed since.
fn item_cache<R: Runtime>(app: &AppHandle<R>, id: u64, path: &Path) -> Result<PathBuf, String> {
    let dir = cache_dir(app)?.join(id.to_string());
    let meta = fs::metadata(path).map_err(|e| format!("el archivo ya no está ({e})"))?;
    let stamp = format!("{}:{}", meta.len(), meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0));
    if fs::read_to_string(dir.join("stamp")).ok().as_deref() != Some(stamp.as_str()) {
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        fs::write(dir.join("stamp"), &stamp).map_err(|e| e.to_string())?;
    }
    Ok(dir)
}

/// The file of an item and the archive it really is (see `container_of`): what the readers open.
fn known<R: Runtime>(app: &AppHandle<R>, id: u64) -> Result<(PathBuf, String), String> {
    let (path, format) = app.state::<Shelf>().known.lock().unwrap().get(&id).cloned()
        .ok_or_else(|| "ese archivo no está en la estantería".to_string())?;
    let container = container_of(&path, &format);
    Ok((path, container))
}

/// What the viewer needs before reading: how many pages and their sizes (a cbr or cb7 gets
/// unpacked now; a PDF is only counted, unless `pdf_pages`... it is the same: pages are rendered on demand).
#[derive(Serialize)]
pub struct Prepared {
    pages: usize,
    page_sizes: Vec<[u32; 2]>,
}

fn prepare<R: Runtime>(app: &AppHandle<R>, id: u64) -> Result<Prepared, String> {
    let (path, format) = known(app, id)?;
    if format == "djvu" {
        return Err("un DjVu lo pagina el visor con el archivo entero; aquí no se prepara".into());
    }
    let dir = item_cache(app, id, &path)?;
    touch(&dir);
    if let Ok(data) = fs::read(dir.join("prepared.json")) {
        if let Ok(v) = serde_json::from_slice::<Value>(&data) {
            if let (Some(pages), Some(sizes)) = (v["pages"].as_u64(), v["page_sizes"].as_array()) {
                let page_sizes = sizes.iter().filter_map(|s| Some([s[0].as_u64()? as u32, s[1].as_u64()? as u32])).collect();
                if format == "cbz" && !app.state::<Shelf>().zips.lock().unwrap().contains_key(&id) {
                    let names = zip_pages(&path)?;
                    app.state::<Shelf>().zips.lock().unwrap().insert(id, names);
                }
                if format == "cbt" && !app.state::<Shelf>().tars.lock().unwrap().contains_key(&id) {
                    let pages = tar_pages(&path)?;
                    app.state::<Shelf>().tars.lock().unwrap().insert(id, pages);
                }
                return Ok(Prepared { pages: pages as usize, page_sizes });
            }
        }
    }
    let (pages, page_sizes): (usize, Vec<[u32; 2]>) = match format.as_str() {
        "cbz" => {
            let names = zip_pages(&path)?;
            if names.is_empty() {
                return Err("no tiene imágenes".into());
            }
            let sizes = names.iter().map(|n| zip_read(&path, n, Some(256 << 10)).ok()
                .and_then(|d| imagesize::blob_size(&d).ok()).map(|s| [s.width as u32, s.height as u32]).unwrap_or([0, 0])).collect();
            let count = names.len();
            app.state::<Shelf>().zips.lock().unwrap().insert(id, names);
            (count, sizes)
        }
        "cbt" => {
            let pages = tar_pages(&path)?;
            if pages.is_empty() {
                return Err("no tiene imágenes".into());
            }
            let sizes = pages.iter().map(|p| tar_read(&path, p, Some(256 << 10)).ok()
                .and_then(|d| imagesize::blob_size(&d).ok()).map(|s| [s.width as u32, s.height as u32]).unwrap_or([0, 0])).collect();
            let count = pages.len();
            app.state::<Shelf>().tars.lock().unwrap().insert(id, pages);
            (count, sizes)
        }
        "cbr" | "cb7" => {
            let count = unpack(&path, &format, &dir.join("x"))?;
            let pages_dir = dir.join("x").join("p");
            let sizes = (0..count).map(|n| find(&pages_dir, &n.to_string()).and_then(|p| imagesize::size(p).ok())
                .map(|s| [s.width as u32, s.height as u32]).unwrap_or([0, 0])).collect();
            prune(app, id);
            (count, sizes)
        }
        "pdf" => pdf_info(pdfium(app)?, &path)?,
        _ => (0, vec![]),
    };
    let page_sizes = if page_sizes.iter().any(|s| s[0] == 0 || s[1] == 0) { vec![] } else { page_sizes };
    let _ = fs::write(dir.join("prepared.json"), serde_json::to_vec(&json!({ "pages": pages, "page_sizes": page_sizes })).unwrap_or_default());
    Ok(Prepared { pages, page_sizes })
}

#[tauri::command]
pub async fn shelf_prepare<R: Runtime>(app: AppHandle<R>, id: u64) -> Result<Prepared, String> {
    tauri::async_runtime::spawn_blocking(move || prepare(&app, id)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn shelf_set_cache_limit<R: Runtime>(app: AppHandle<R>, shelf: State<'_, Shelf>, bytes: u64) -> Result<(), String> {
    with_config(&app, &shelf, |c| c.cache_limit = Some(bytes.max(256 << 20)))?;
    prune(&app, 0);
    Ok(())
}

#[tauri::command]
pub fn shelf_clear_cache<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let dir = cache_dir(&app)?;
    if let Ok(entries) = fs::read_dir(&dir) {
        for e in entries.flatten() {
            if e.file_name() != "covers" {
                let _ = fs::remove_dir_all(e.path());
            }
        }
    }
    Ok(())
}

/// Opens the file in its Windows app (the one its type opens with), or shows it in the Explorer.
#[tauri::command]
pub fn shelf_reveal<R: Runtime>(app: AppHandle<R>, id: u64) -> Result<(), String> {
    let (path, _) = known(&app, id)?;
    std::process::Command::new("explorer").arg(format!("/select,{}", path.display())).spawn().map_err(|e| e.to_string())?;
    Ok(())
}

// ---- the protocol ----

fn cover<R: Runtime>(app: &AppHandle<R>, id: u64) -> Result<(Vec<u8>, &'static str), String> {
    let covers = cache_dir(app)?.join("covers");
    let (path, format) = known(app, id)?;
    let changed = fs::metadata(&path).and_then(|m| m.modified()).ok();
    for (ext, mime) in [("jpg", "image/jpeg"), ("avif", "image/avif")] {
        let file = covers.join(format!("{id}.{ext}"));
        let made = fs::metadata(&file).and_then(|m| m.modified()).ok();
        if let (Some(made), Some(changed)) = (made, changed) {
            if made >= changed {
                return Ok((fs::read(&file).map_err(|e| e.to_string())?, mime));
            }
        }
    }
    let raw: Vec<u8> = match format.as_str() {
        "cbz" => {
            let names = zip_pages(&path)?;
            zip_read(&path, names.first().ok_or("no tiene imágenes")?, None)?
        }
        "cbt" => {
            let pages = tar_pages(&path)?;
            tar_read(&path, pages.first().ok_or("no tiene imágenes")?, None)?
        }
        "cbr" | "cb7" => first_image(&path, &format)?,
        "pdf" => pdf_render(pdfium(app)?, &path, 0, COVER_WIDTH)?,
        "djvu" => djvu_render(&fs::read(&path).map_err(|e| e.to_string())?, COVER_WIDTH)?,
        "epub" => epub_cover(&path).ok_or("sin portada")?,
        "mobi" => mobi_cover(&mut BufReader::new(fs::File::open(&path).map_err(|e| e.to_string())?)).ok_or("sin portada")?,
        "fb2" => fb2_cover(fs::File::open(&path).map_err(|e| e.to_string())?).ok_or("sin portada")?,
        "fbz" => fbz_cover(&path).ok_or("sin portada")?,
        _ => return Err("sin portada".into()),
    };
    let (data, ext, mime) = match small(&raw) {
        Ok(data) => (data, "jpg", "image/jpeg"),
        // an AVIF cannot be made small here (see `decode`): it goes as it is, and WebView2 shows it
        Err(_) if is_avif(&raw) => (raw, "avif", "image/avif"),
        Err(e) => return Err(e),
    };
    fs::create_dir_all(&covers).map_err(|e| e.to_string())?;
    let _ = fs::remove_file(covers.join(format!("{id}.{}", if ext == "jpg" { "avif" } else { "jpg" })));
    let _ = fs::write(covers.join(format!("{id}.{ext}")), &data);
    Ok((data, mime))
}

/// The first page of a rar or 7z, by name, without unpacking the rest (when the archive lets).
fn first_image(path: &Path, format: &str) -> Result<Vec<u8>, String> {
    if format == "cbr" {
        let mut names = vec![];
        let archive = unrar::Archive::new(path).open_for_listing().map_err(|e| e.to_string())?;
        for header in archive {
            let header = header.map_err(|e| e.to_string())?;
            let name = header.filename.to_string_lossy().into_owned();
            if header.is_file() && image_ext(&name).is_some() {
                names.push(name);
            }
        }
        names.sort_by(|a, b| natural(a, b));
        let wanted = names.first().ok_or("no tiene imágenes")?.clone();
        let mut archive = unrar::Archive::new(path).open_for_processing().map_err(|e| e.to_string())?;
        while let Some(header) = archive.read_header().map_err(|e| e.to_string())? {
            if header.entry().filename.to_string_lossy() == wanted {
                return Ok(header.read().map_err(|e| e.to_string())?.0);
            }
            archive = header.skip().map_err(|e| e.to_string())?;
        }
        Err("no tiene imágenes".into())
    } else {
        let mut reader = sevenz_rust::SevenZReader::open(path, sevenz_rust::Password::empty()).map_err(|e| e.to_string())?;
        let mut names: Vec<String> = reader.archive().files.iter().filter(|f| !f.is_directory() && image_ext(f.name()).is_some()).map(|f| f.name().to_string()).collect();
        names.sort_by(|a, b| natural(a, b));
        let wanted = names.first().ok_or("no tiene imágenes")?.clone();
        let mut found: Option<Vec<u8>> = None;
        reader.for_each_entries(|entry, r| {
            if entry.name() == wanted {
                let mut data = vec![];
                r.read_to_end(&mut data)?;
                found = Some(data);
                return Ok(false);
            }
            io::copy(r, &mut io::sink())?;
            Ok(true)
        }).map_err(|e| e.to_string())?;
        found.ok_or_else(|| "no tiene imágenes".into())
    }
}

fn page<R: Runtime>(app: &AppHandle<R>, id: u64, n: usize, width: Option<u32>) -> Result<(Vec<u8>, &'static str), String> {
    let (path, format) = known(app, id)?;
    let (data, ext) = match format.as_str() {
        "cbz" => {
            let names = {
                let cached = app.state::<Shelf>().zips.lock().unwrap().get(&id).cloned();
                match cached { Some(n) => n, None => { prepare(app, id)?; app.state::<Shelf>().zips.lock().unwrap().get(&id).cloned().unwrap_or_default() } }
            };
            let name = names.get(n).ok_or("esa página no existe")?;
            (zip_read(&path, name, None)?, image_ext(name).unwrap_or_default())
        }
        "cbt" => {
            let pages = {
                let cached = app.state::<Shelf>().tars.lock().unwrap().get(&id).cloned();
                match cached { Some(p) => p, None => { prepare(app, id)?; app.state::<Shelf>().tars.lock().unwrap().get(&id).cloned().unwrap_or_default() } }
            };
            let page = pages.get(n).ok_or("esa página no existe")?;
            (tar_read(&path, page, None)?, image_ext(&page.name).unwrap_or_default())
        }
        "cbr" | "cb7" => {
            let dir = item_cache(app, id, &path)?.join("x").join("p");
            let file = match find(&dir, &n.to_string()) { Some(f) => f, None => { prepare(app, id)?; find(&dir, &n.to_string()).ok_or("esa página no existe")? } };
            let ext = file.extension().and_then(|e| e.to_str()).unwrap_or("").to_string();
            (fs::read(&file).map_err(|e| e.to_string())?, ext)
        }
        "pdf" => {
            let width = width.unwrap_or(1600).clamp(300, 3200);
            let dir = item_cache(app, id, &path)?;
            touch(&dir);
            let file = dir.join(format!("r{n}-{width}.jpg"));
            if let Ok(data) = fs::read(&file) {
                return Ok((data, "image/jpeg"));
            }
            let data = pdf_render(pdfium(app)?, &path, n, width)?;
            let _ = fs::write(&file, &data);
            prune(app, id);
            return Ok((data, "image/jpeg"));
        }
        "djvu" => return Err("las páginas de un DjVu las dibuja el visor con el archivo entero".into()),
        _ => return Err("un libro no se sirve por páginas".into()),
    };
    if ext != "jxl" {
        return Ok((data, mime_of(&ext)));
    }
    // WebView2 cannot show a JPEG XL: it is made JPEG once and kept with the item's cache
    let dir = item_cache(app, id, &path)?;
    touch(&dir);
    let file = dir.join(format!("j{n}.jpg"));
    if let Ok(done) = fs::read(&file) {
        return Ok((done, "image/jpeg"));
    }
    let done = jpeg(&decode(&data)?, 90)?;
    let _ = fs::write(&file, &done);
    prune(app, id);
    Ok((done, "image/jpeg"))
}

fn whole<R: Runtime>(app: &AppHandle<R>, id: u64) -> Result<(Vec<u8>, &'static str), String> {
    let (path, format) = known(app, id)?;
    Ok((fs::read(&path).map_err(|e| e.to_string())?, mime_of(&format)))
}

fn answer(request: &Request<Vec<u8>>, app: &AppHandle<impl Runtime>) -> Response<Cow<'static, [u8]>> {
    let respond = |status: u16, mime: &str, body: Vec<u8>, cache: bool| {
        Response::builder()
            .status(status)
            .header("Content-Type", mime)
            .header("Access-Control-Allow-Origin", "*")
            .header("Cache-Control", if cache { "private, max-age=600" } else { "no-store" })
            .body(Cow::Owned(body))
            .unwrap()
    };
    let path = request.uri().path().trim_matches('/').to_string();
    let width = request.uri().query().and_then(|q| q.split('&').find_map(|kv| kv.strip_prefix("w=")?.parse::<u32>().ok()));
    let parts: Vec<&str> = path.split('/').collect();
    let id = parts.get(1).and_then(|s| s.parse::<u64>().ok());
    let found = match (parts.first().copied(), id, parts.get(2)) {
        (Some("c"), Some(id), None) => cover(app, id),
        (Some("p"), Some(id), Some(n)) => n.parse::<usize>().map_err(|e| e.to_string()).and_then(|n| page(app, id, n, width)),
        (Some("f"), Some(id), None) => whole(app, id),
        _ => Err("no existe".into()),
    };
    match found {
        Ok((data, mime)) => respond(200, mime, data, true),
        Err(e) => respond(404, "text/plain; charset=utf-8", e.into_bytes(), false),
    }
}

/// The `shelf` protocol, answered away from the window's thread (unpacking and rendering take a while).
pub fn serve<R: Runtime>(ctx: UriSchemeContext<'_, R>, request: Request<Vec<u8>>, responder: UriSchemeResponder) {
    let app = ctx.app_handle().clone();
    thread::spawn(move || responder.respond(answer(&request, &app)));
}

// ---- up to the Archivador ----

/// A piece of a file read out a little at a time, telling how far (the progress of an upload).
struct Counted<'a, F: FnMut(u64)> {
    data: &'a [u8],
    at: usize,
    tell: F,
}

impl<F: FnMut(u64)> Read for Counted<'_, F> {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        let n = (self.data.len() - self.at).min(out.len()).min(1 << 16);
        out[..n].copy_from_slice(&self.data[self.at..self.at + n]);
        self.at += n;
        (self.tell)(self.at as u64);
        Ok(n)
    }
}

#[derive(Serialize, Clone)]
struct UploadProgress {
    id: u64,
    sent: u64,
    total: u64,
}

/// Puts a file of the shelf in the reading folder of the user's Archivador (through La Estantería's
/// service, a piece at a time: requests through Cloudflare carry at most 100 MB); the new item.
#[tauri::command]
pub async fn shelf_upload<R: Runtime>(app: AppHandle<R>, id: u64, base: String, authorization: String, dest: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let (path, _) = known(&app, id)?;
        let total = fs::metadata(&path).map_err(|e| e.to_string())?.len();
        let agent = ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(15)).timeout_read(Duration::from_secs(900)).build();
        let base = base.trim_end_matches('/');
        let fail = |e: ureq::Error| match e {
            ureq::Error::Status(code, r) => r.into_string().ok()
                .and_then(|b| serde_json::from_str::<Value>(&b).ok())
                .and_then(|v| v["detail"].as_str().map(String::from))
                .unwrap_or_else(|| format!("HTTP {code}")),
            other => format!("sin conexión ({other})"),
        };
        let body = json!({ "path": dest, "size": total }).to_string();
        let started: Value = agent.post(&format!("{base}/api/uploads")).set("Authorization", &authorization)
            .set("Content-Type", "application/json").send_string(&body).map_err(fail)?
            .into_string().ok().and_then(|t| serde_json::from_str(&t).ok()).ok_or("el servicio no empezó la subida")?;
        let upload = started["id"].as_str().ok_or("el servicio no empezó la subida")?.to_string();
        let chunk = started["chunk"].as_u64().map(|c| c as usize).unwrap_or(UPLOAD_CHUNK).min(UPLOAD_CHUNK);
        let mut file = fs::File::open(&path).map_err(|e| e.to_string())?;
        let mut sent: u64 = 0;
        let mut buf = vec![0u8; chunk];
        while sent < total {
            let mut filled = 0;
            while filled < chunk {
                let got = file.read(&mut buf[filled..]).map_err(|e| e.to_string())?;
                if got == 0 { break; }
                filled += got;
            }
            if filled == 0 { break; }
            let mut attempt = 0;
            loop {
                attempt += 1;
                // how it goes, told as the bytes leave (not only per piece: a small file would jump from 0 to 100)
                let from = sent;
                let mut told = Instant::now();
                let body = Counted { data: &buf[..filled], at: 0, tell: |at: u64| {
                    if told.elapsed() >= Duration::from_millis(250) {
                        told = Instant::now();
                        let _ = app.emit("shelf-upload", UploadProgress { id, sent: from + at, total });
                    }
                } };
                match agent.put(&format!("{base}/api/uploads/{upload}?offset={sent}")).set("Authorization", &authorization)
                    .set("Content-Type", "application/octet-stream").set("Content-Length", &filled.to_string()).send(body) {
                    Ok(_) => break,
                    Err(ureq::Error::Status(409, _)) | Err(ureq::Error::Status(413, _)) if attempt > 1 => break,
                    Err(e) if attempt >= 4 => {
                        let _ = agent.delete(&format!("{base}/api/uploads/{upload}")).set("Authorization", &authorization).call();
                        return Err(fail(e));
                    }
                    Err(_) => thread::sleep(Duration::from_secs(2 * attempt)),
                }
            }
            sent += filled as u64;
            let _ = app.emit("shelf-upload", UploadProgress { id, sent, total });
        }
        let done: Value = agent.post(&format!("{base}/api/uploads/{upload}/finish")).set("Authorization", &authorization)
            .call().map_err(fail)?.into_string().ok().and_then(|t| serde_json::from_str(&t).ok()).ok_or("el servicio no acabó la subida")?;
        Ok(done)
    }).await.map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn natural_order() {
        let mut names = vec!["p10.jpg", "p2.jpg", "P1.jpg", "p02b.jpg", "cover.jpg"];
        names.sort_by(|a, b| natural(a, b));
        assert_eq!(names, vec!["cover.jpg", "P1.jpg", "p2.jpg", "p02b.jpg", "p10.jpg"]);
    }

    #[test]
    fn images_only() {
        assert_eq!(image_ext("a/b/001.JPEG").as_deref(), Some("jpg"));
        assert_eq!(image_ext("ComicInfo.xml"), None);
        assert_eq!(image_ext("__MACOSX/._001.jpg"), None);
        assert_eq!(image_ext("a/.hidden.png"), None);
    }

    #[test]
    fn same_file_same_id() {
        let tmp = std::env::temp_dir().join(format!("estanteria-id-{}.cbz", std::process::id()));
        fs::write(&tmp, b"x").unwrap();
        let a = id_of(&tmp);
        fs::write(&tmp, b"changed").unwrap();
        assert_eq!(a, id_of(&tmp));
        assert!(a >= LOCAL_BASE && a < LOCAL_BASE + (1 << 40));
        let _ = fs::remove_file(&tmp);
    }

    /// A one-page PDF (A6, 297 × 420 pt) with a line of text.
    fn tiny_pdf(path: &Path) {
        let body = "BT /F1 24 Tf 40 300 Td (Hola) Tj ET";
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 297 420] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>".to_string(),
            format!("<< /Length {} >>\nstream\n{body}\nendstream", body.len()),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string(),
        ];
        let mut out = String::from("%PDF-1.4\n");
        let mut offsets = vec![];
        for (i, o) in objects.iter().enumerate() {
            offsets.push(out.len());
            out += &format!("{} 0 obj\n{o}\nendobj\n", i + 1);
        }
        let xref = out.len();
        out += &format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1);
        for o in offsets { out += &format!("{o:010} 00000 n \n"); }
        out += &format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n", objects.len() + 1);
        fs::write(path, out).unwrap();
    }

    #[test]
    fn pdf_pages_with_pdfium() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("pdfium");
        let Ok(bindings) = Pdfium::bind_to_library(Pdfium::pdfium_platform_library_name_at_path(&dir)) else {
            eprintln!("sin pdfium.dll en {}: se salta", dir.display());
            return;
        };
        let pdfium = Pdfium::new(bindings);
        let tmp = std::env::temp_dir().join(format!("estanteria-pdf-{}.pdf", std::process::id()));
        tiny_pdf(&tmp);
        let (pages, sizes) = pdf_info(&pdfium, &tmp).unwrap();
        assert_eq!((pages, sizes), (1, vec![[594, 840]]));
        let jpg = pdf_render(&pdfium, &tmp, 0, 600).unwrap();
        let img = image::load_from_memory(&jpg).unwrap();
        assert_eq!((img.width(), img.height()), (600, 848));
        assert!(pdf_render(&pdfium, &tmp, 3, 600).is_err());
        let _ = fs::remove_file(&tmp);
    }

    #[test]
    fn epub_cover_from_the_package() {
        let tmp = std::env::temp_dir().join(format!("estanteria-epub-{}.epub", std::process::id()));
        {
            use std::io::Write;
            let mut zip = zip::ZipWriter::new(fs::File::create(&tmp).unwrap());
            let opts = zip::write::SimpleFileOptions::default();
            zip.start_file("OEBPS/content.opf", opts).unwrap();
            zip.write_all(br#"<package><metadata><meta name="cover" content="c1"/></metadata><manifest><item id="c1" href="img/portada.jpg" media-type="image/jpeg"/></manifest></package>"#).unwrap();
            zip.start_file("OEBPS/img/portada.jpg", opts).unwrap();
            zip.write_all(b"JPEGDATA").unwrap();
            zip.finish().unwrap();
        }
        assert_eq!(epub_cover(&tmp).as_deref(), Some(&b"JPEGDATA"[..]));
        let _ = fs::remove_file(&tmp);
    }

    #[test]
    fn zip_pages_in_order() {
        let tmp = std::env::temp_dir().join(format!("estanteria-zip-{}.cbz", std::process::id()));
        {
            use std::io::Write;
            let mut zip = zip::ZipWriter::new(fs::File::create(&tmp).unwrap());
            let opts = zip::write::SimpleFileOptions::default();
            for name in ["10.png", "2.png", "ComicInfo.xml", "1.png", "__MACOSX/._1.png"] {
                zip.start_file(name, opts).unwrap();
                zip.write_all(b"data").unwrap();
            }
            zip.finish().unwrap();
        }
        assert_eq!(zip_pages(&tmp).unwrap(), vec!["1.png", "2.png", "10.png"]);
        assert_eq!(zip_read(&tmp, "2.png", None).unwrap(), b"data");
        let _ = fs::remove_file(&tmp);
    }

    #[test]
    fn formats_by_name() {
        assert_eq!(format_of_name("Libro.FB2.zip"), Some("fbz"));
        assert_eq!(format_of_name("Comic 01.zip"), Some("cbz"));
        assert_eq!(format_of_name("x.fbz"), Some("fbz"));
        assert_eq!(format_of_name("x.fb2"), Some("fb2"));
        assert_eq!(format_of_name("x.AZW3"), Some("mobi"));
        assert_eq!(format_of_name("x.azw"), Some("mobi"));
        assert_eq!(format_of_name("x.prc"), Some("mobi"));
        assert_eq!(format_of_name("x.mobi"), Some("mobi"));
        assert_eq!(format_of_name("x.cbt"), Some("cbt"));
        assert_eq!(format_of_name("x.tar"), Some("cbt"));
        assert_eq!(format_of_name("léeme.txt"), Some("txt"));
        assert_eq!(format_of_name("x.DjVu"), Some("djvu"));
        assert_eq!(format_of_name("x.djv"), Some("djvu"));
        assert_eq!(format_of_name("x.djvu.zip"), Some("cbz"));
        assert_eq!(format_of_name("x.cbz2"), None);
        assert_eq!(format_of_name("fb2"), None);
        assert_eq!(format_of(Path::new(r"C:\a.b\Libro.fb2.zip")), Some("fbz"));
    }

    /// A tar with some pages, out of order, a long name and something that is not a page.
    fn tiny_tar() -> Vec<u8> {
        let mut builder = tar::Builder::new(vec![]);
        let long = format!("{}/3.jpg", "carpeta-de-nombre-largo".repeat(6));
        for (name, data) in [("10.png", &b"ten"[..]), ("2.png", b"two"), ("ComicInfo.xml", b"<x/>"), ("1.png", b"one"), (long.as_str(), b"three")] {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, name, data).unwrap();
        }
        builder.into_inner().unwrap()
    }

    #[test]
    fn tar_pages_by_offset() {
        let data = tiny_tar();
        assert_eq!(container_by_head(&data), Some("cbt"));
        let pages = tar_index(io::Cursor::new(&data)).unwrap();
        let names: Vec<&str> = pages.iter().map(|p| p.name.rsplit('/').next().unwrap()).collect();
        assert_eq!(names, vec!["1.png", "2.png", "10.png", "3.jpg"]);      // the folder's page after the top's
        assert!(pages[3].name.len() > 100);
        let read = |p: &TarPage| data[p.offset as usize..(p.offset + p.size) as usize].to_vec();
        assert_eq!(read(&pages[0]), b"one");
        assert_eq!(read(&pages[2]), b"ten");
        assert_eq!(read(&pages[3]), b"three");

        let tmp = std::env::temp_dir().join(format!("estanteria-tar-{}.cbt", std::process::id()));
        fs::write(&tmp, &data).unwrap();
        let pages = tar_pages(&tmp).unwrap();
        assert_eq!(tar_read(&tmp, &pages[1], None).unwrap(), b"two");
        assert_eq!(tar_read(&tmp, &pages[1], Some(1)).unwrap(), b"t");
        assert_eq!(container_of(&tmp, "cbz"), "cbt");
        let _ = fs::remove_file(&tmp);
    }

    /// A MOBI (a PalmDB): record 0 with the MOBI header (and EXTH with `exth`), a text record, then
    /// a record that is not a picture and two pictures; the first image is record 2.
    fn tiny_mobi(exth: &[(u32, u32)]) -> Vec<u8> {
        let mut first = vec![0u8; 16];                      // PalmDOC header
        let mut mobi = vec![0u8; 232];                      // the MOBI header (its length is 232)
        mobi[0..4].copy_from_slice(b"MOBI");
        mobi[4..8].copy_from_slice(&232u32.to_be_bytes());
        mobi[92..96].copy_from_slice(&2u32.to_be_bytes()); // first image (record offset 108)
        mobi[112..116].copy_from_slice(&0x40u32.to_be_bytes());
        first.extend(mobi);
        if !exth.is_empty() {
            let mut records = vec![];
            for (kind, value) in exth {
                records.extend(kind.to_be_bytes());
                records.extend(12u32.to_be_bytes());
                records.extend(value.to_be_bytes());
            }
            first.extend(b"EXTH");
            first.extend((12 + records.len() as u32).to_be_bytes());
            first.extend((exth.len() as u32).to_be_bytes());
            first.extend(records);
        }
        let records: Vec<Vec<u8>> = vec![first, b"text".to_vec(), b"FLIS-not-a-picture".to_vec(),
                                         b"\xff\xd8\xff\xe0first".to_vec(), b"\x89PNG\r\n\x1a\nsecond".to_vec()];
        let mut out = vec![0u8; 78];
        out[60..68].copy_from_slice(b"BOOKMOBI");
        out[76..78].copy_from_slice(&(records.len() as u16).to_be_bytes());
        let mut at = 78 + records.len() * 8 + 2;
        for (i, r) in records.iter().enumerate() {
            out.extend((at as u32).to_be_bytes());
            out.extend([0, 0, 0, i as u8]);
            at += r.len();
        }
        out.extend([0, 0]);
        for r in records {
            out.extend(r);
        }
        out
    }

    #[test]
    fn mobi_cover_by_exth() {
        let cover = |exth: &[(u32, u32)]| mobi_cover(&mut io::Cursor::new(tiny_mobi(exth)));
        // 201: the cover, counted from the first image
        assert_eq!(cover(&[(201, 2)]).unwrap(), b"\x89PNG\r\n\x1a\nsecond");
        // 201 names what is not a picture: 202, the thumbnail
        assert_eq!(cover(&[(202, 1), (201, 0)]).unwrap(), b"\xff\xd8\xff\xe0first");
        // none named (or none there): the first picture
        assert_eq!(cover(&[]).unwrap(), b"\xff\xd8\xff\xe0first");
        assert_eq!(cover(&[(201, 0xffff_ffff), (201, 40)]).unwrap(), b"\xff\xd8\xff\xe0first");
        // not a MOBI
        assert!(mobi_cover(&mut io::Cursor::new(vec![0u8; 200])).is_none());
    }

    const FB2: &str = r##"<?xml version="1.0" encoding="windows-1251"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<description><title-info><book-title>TITLE</book-title>
<coverpage><image l:href="#cover.jpg"/></coverpage></title-info></description>
<body><section><p>A &amp; B &nbsp; <image l:href="#pic.png"/></p></section></body>
<binary id="pic.png" content-type="image/png">iVBORw0K</binary>
<binary id="cover.jpg" content-type="image/jpeg">
/9j/4AAQ
SkZJRg==
</binary>
</FictionBook>"##;

    #[test]
    fn fb2_cover_from_its_binary() {
        // a title in Windows-1251 (not UTF-8): the reader still gets through
        let mut data = FB2.replace("TITLE", "\u{1}").into_bytes();
        let at = data.iter().position(|&b| b == 1).unwrap();
        data.splice(at..at + 1, [0xc2, 0xee, 0xe9, 0xed, 0xe0]);
        assert_eq!(fb2_cover(&data[..]).unwrap(), b"\xff\xd8\xff\xe0\x00\x10JFIF");
        // no coverpage: a binary called cover
        let plain = FB2.replace(r##"<coverpage><image l:href="#cover.jpg"/></coverpage>"##, "");
        assert_eq!(fb2_cover(plain.as_bytes()).unwrap(), b"\xff\xd8\xff\xe0\x00\x10JFIF");
        let none = plain.replace("cover.jpg", "other.jpg");
        assert!(fb2_cover(none.as_bytes()).is_none());

        // an FBZ: the FB2 zipped
        let tmp = std::env::temp_dir().join(format!("estanteria-fbz-{}.fb2.zip", std::process::id()));
        {
            use std::io::Write;
            let mut zip = zip::ZipWriter::new(fs::File::create(&tmp).unwrap());
            let opts = zip::write::SimpleFileOptions::default();
            zip.start_file("libro.fb2", opts).unwrap();
            zip.write_all(FB2.as_bytes()).unwrap();
            zip.finish().unwrap();
        }
        assert_eq!(format_of(&tmp), Some("fbz"));
        assert_eq!(fbz_cover(&tmp).unwrap(), b"\xff\xd8\xff\xe0\x00\x10JFIF");
        let _ = fs::remove_file(&tmp);
    }

    #[test]
    fn latin1_is_utf8() {
        let raw = [b'a', 0xe9, 0xff, b'z'];
        let mut out = vec![];
        Latin1 { inner: &raw[..], pending: None }.read_to_end(&mut out).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "aéÿz");
        // a buffer of one byte: the second half of a character waits for the next read
        let mut reader = Latin1 { inner: &raw[..], pending: None };
        let mut out = vec![];
        let mut one = [0u8; 1];
        while reader.read(&mut one).unwrap() == 1 {
            out.push(one[0]);
        }
        assert_eq!(String::from_utf8(out).unwrap(), "aéÿz");
    }

    #[test]
    fn pictures_by_their_first_bytes() {
        assert!(is_avif(b"\0\0\0\x1cftypavif\0\0\0\0"));
        assert!(!is_avif(b"\0\0\0\x1cftypheic\0\0\0\0"));
        assert!(is_jxl(b"\xff\x0a\xfa"));
        assert!(is_jxl(b"\0\0\0\x0cJXL \r\n\x87\n\0\0"));
        assert!(!is_jxl(b"\xff\xd8\xff"));
    }

    #[test]
    fn djvu_cover_of_page_one() {
        // a bilevel page made with djvu-rs' own encoder: white, with a black square at the top left
        let mut bitmap = djvu_rs::Bitmap::new(800, 1000);
        for y in 0..400 {
            for x in 0..400 {
                bitmap.set_black(x, y);
            }
        }
        let file = djvu_rs::djvu_encode::PageEncoder::from_bitmap(&bitmap).with_dpi(300).encode().unwrap();
        let jpg = djvu_render(&file, COVER_WIDTH).unwrap();
        let img = image::load_from_memory(&jpg).unwrap().to_luma8();
        assert_eq!((img.width(), img.height()), (400, 500));
        assert!(img.get_pixel(50, 50).0[0] < 60);
        assert!(img.get_pixel(350, 450).0[0] > 200);
        assert!(djvu_render(b"AT&TFORM not really", COVER_WIDTH).is_err());
    }

    /// An 8 × 6 lossless JPEG XL: red, with the first half of the top row blue.
    const TINY_JXL: [u8; 42] = [
        0xff, 0x0a, 0x28, 0x30, 0x10, 0x09, 0x08, 0x00, 0x01, 0x00, 0x78, 0x00, 0x4b, 0x38, 0x69, 0x98, 0xca, 0x83, 0xf7, 0x2b, 0x48,
        0x48, 0x38, 0x49, 0xa8, 0xbc, 0x40, 0x04, 0x00, 0x43, 0x3e, 0x15, 0xad, 0x84, 0x93, 0x70, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    #[test]
    fn jxl_made_jpeg() {
        let img = decode(&TINY_JXL).unwrap().to_rgb8();
        assert_eq!((img.width(), img.height()), (8, 6));
        assert_eq!(img.get_pixel(0, 0).0, [0, 0, 255]);
        assert_eq!(img.get_pixel(7, 5).0, [200, 30, 40]);
        let jpg = jpeg(&decode(&TINY_JXL).unwrap(), 90).unwrap();
        assert!(jpg.starts_with(&[0xff, 0xd8]));
        assert_eq!(image::load_from_memory(&small(&TINY_JXL).unwrap()).unwrap().width(), 8);
    }
}
