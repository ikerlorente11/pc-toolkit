//! The shelf of this computer: folders the user adds as libraries, and files opened one by one (a
//! double click in the Explorer, «Abrir con», a file dropped on the window). Nothing is copied when
//! they are listed; the viewer reads them through the `shelf` protocol:
//!
//! - `/c/<id>`: a small cover (the first page, made 400 px wide, kept in `local-cache/covers/`);
//! - `/p/<id>/<n>?w=`: a page. A cbz is read straight from the archive; a cbr or cb7 is unpacked
//!   once into `local-cache/<id>/` (reading one page of a rar or a 7z means reading all before
//!   it), and a PDF page is rendered by PDFium at the width asked and kept there too. That cache
//!   has a size limit: what was opened longest ago goes first;
//! - `/f/<id>`: the file itself (an EPUB, or a PDF for the document reader).
//!
//! An item's id is `LOCAL_BASE` + a hash of its path, so the same file is the same item (with its
//! progress and notes) every time, and never meets an id of the service (those count from 1).

use std::borrow::Cow;
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
    match path.extension()?.to_str()?.to_lowercase().as_str() {
        "cbz" | "zip" => Some("cbz"),
        "cbr" | "rar" => Some("cbr"),
        "cb7" | "7z" => Some("cb7"),
        "epub" => Some("epub"),
        "pdf" => Some("pdf"),
        _ => None,
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
    let format = format_of(&file).ok_or("La Estantería abre cbz, cbr, cb7, epub y pdf")?;
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
        "pdf" => "application/pdf",
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

fn jpeg(img: &image::DynamicImage, quality: u8) -> Result<Vec<u8>, String> {
    let mut out = vec![];
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality)
        .encode_image(&img.to_rgb8())
        .map_err(|e| e.to_string())?;
    Ok(out)
}

fn small(data: &[u8]) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data).map_err(|e| e.to_string())?;
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

fn known<R: Runtime>(app: &AppHandle<R>, id: u64) -> Result<(PathBuf, String), String> {
    app.state::<Shelf>().known.lock().unwrap().get(&id).cloned().ok_or_else(|| "ese archivo no está en la estantería".into())
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
    let dir = item_cache(app, id, &path)?;
    touch(&dir);
    if let Ok(data) = fs::read(dir.join("prepared.json")) {
        if let Ok(v) = serde_json::from_slice::<Value>(&data) {
            if let (Some(pages), Some(sizes)) = (v["pages"].as_u64(), v["page_sizes"].as_array()) {
                let page_sizes = sizes.iter().filter_map(|s| Some([s[0].as_u64()? as u32, s[1].as_u64()? as u32])).collect();
                if format == "cbz" {
                    app.state::<Shelf>().zips.lock().unwrap().entry(id).or_insert(zip_pages(&path)?);
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
    let file = covers.join(format!("{id}.jpg"));
    let (path, format) = known(app, id)?;
    let changed = fs::metadata(&path).and_then(|m| m.modified()).ok();
    let made = fs::metadata(&file).and_then(|m| m.modified()).ok();
    if let (Some(made), Some(changed)) = (made, changed) {
        if made >= changed {
            return Ok((fs::read(&file).map_err(|e| e.to_string())?, "image/jpeg"));
        }
    }
    let raw: Vec<u8> = match format.as_str() {
        "cbz" => {
            let names = zip_pages(&path)?;
            zip_read(&path, names.first().ok_or("no tiene imágenes")?, None)?
        }
        "cbr" | "cb7" => first_image(&path, &format)?,
        "pdf" => pdf_render(pdfium(app)?, &path, 0, COVER_WIDTH)?,
        "epub" => epub_cover(&path).ok_or("sin portada")?,
        _ => return Err("sin portada".into()),
    };
    let data = small(&raw)?;
    fs::create_dir_all(&covers).map_err(|e| e.to_string())?;
    let _ = fs::write(&file, &data);
    Ok((data, "image/jpeg"))
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
    match format.as_str() {
        "cbz" => {
            let names = {
                let cached = app.state::<Shelf>().zips.lock().unwrap().get(&id).cloned();
                match cached { Some(n) => n, None => { prepare(app, id)?; app.state::<Shelf>().zips.lock().unwrap().get(&id).cloned().unwrap_or_default() } }
            };
            let name = names.get(n).ok_or("esa página no existe")?;
            Ok((zip_read(&path, name, None)?, mime_of(&image_ext(name).unwrap_or_default())))
        }
        "cbr" | "cb7" => {
            let dir = item_cache(app, id, &path)?.join("x").join("p");
            let file = match find(&dir, &n.to_string()) { Some(f) => f, None => { prepare(app, id)?; find(&dir, &n.to_string()).ok_or("esa página no existe")? } };
            let ext = file.extension().and_then(|e| e.to_str()).unwrap_or("").to_string();
            Ok((fs::read(&file).map_err(|e| e.to_string())?, mime_of(&ext)))
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
            Ok((data, "image/jpeg"))
        }
        _ => Err("un libro no se sirve por páginas".into()),
    }
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
                match agent.put(&format!("{base}/api/uploads/{upload}?offset={sent}")).set("Authorization", &authorization)
                    .set("Content-Type", "application/octet-stream").send_bytes(&buf[..filled]) {
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
}
