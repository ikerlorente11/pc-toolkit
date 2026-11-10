//! Files of this computer (a double click in the Explorer, «Abrir con», a file dropped on the
//! window). A comic is unpacked once into the same layout as a download (`offline/<account>/<id>/`,
//! see offline.rs): its images as pages `p/<n>.<ext>`, the first one as the cover, and `item.json`;
//! an EPUB is copied as `file.epub`. So the viewer reads it like any other item kept offline, from
//! «Descargas», with progress and notes kept on this computer.
//!
//! The id is `LOCAL_BASE` + a hash of the path, size and date of the file: the same file opens as the
//! same item (with its progress), and it never meets an id of the service (those count from 1).

use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::UNIX_EPOCH;

use serde_json::{json, Value};
use tauri::{AppHandle, Manager, Runtime, State};

/// 2^50: from here on, items are files of this computer (the viewer knows it too, see offline.ts).
pub const LOCAL_BASE: u64 = 1 << 50;

const IMAGES: [&str; 8] = ["jpg", "jpeg", "png", "webp", "gif", "avif", "bmp", "jxl"];

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

fn fnv(data: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in data {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

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

/// Unpacks the images of an archive into `pages` (in the archive's order of names); their extensions.
struct Unpacked {
    names: Vec<(String, String, PathBuf)>,
}

impl Unpacked {
    fn keep(&mut self, pages: &Path, name: &str, reader: &mut dyn Read) -> Result<(), String> {
        let Some(ext) = image_ext(name) else { return Ok(()) };
        let tmp = pages.join(format!("x{}.part", self.names.len()));
        let mut out = fs::File::create(&tmp).map_err(|e| e.to_string())?;
        io::copy(reader, &mut out).map_err(|e| e.to_string())?;
        self.names.push((name.to_string(), ext, tmp));
        Ok(())
    }
}

fn unpack_zip(path: &Path, pages: &Path, into: &mut Unpacked) -> Result<(), String> {
    let mut zip = zip::ZipArchive::new(fs::File::open(path).map_err(|e| e.to_string())?).map_err(|e| format!("no es un zip válido ({e})"))?;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| e.to_string())?;
        if entry.is_dir() {
            continue;
        }
        let name = entry.name().to_string();
        into.keep(pages, &name, &mut entry)?;
    }
    Ok(())
}

fn unpack_7z(path: &Path, pages: &Path, into: &mut Unpacked) -> Result<(), String> {
    let mut failed: Option<String> = None;
    sevenz_rust::SevenZReader::open(path, sevenz_rust::Password::empty())
        .map_err(|e| format!("no es un 7z válido ({e})"))?
        .for_each_entries(|entry, reader| {
            if !entry.is_directory() {
                if image_ext(entry.name()).is_some() {
                    if let Err(e) = into.keep(pages, entry.name(), reader) {
                        failed = Some(e);
                        return Ok(false);
                    }
                } else {
                    io::copy(reader, &mut io::sink())?;
                }
            }
            Ok(true)
        })
        .map_err(|e| e.to_string())?;
    failed.map_or(Ok(()), Err)
}

fn unpack_rar(path: &Path, pages: &Path, into: &mut Unpacked) -> Result<(), String> {
    let mut archive = unrar::Archive::new(path).open_for_processing().map_err(|e| format!("no es un rar válido ({e})"))?;
    while let Some(header) = archive.read_header().map_err(|e| e.to_string())? {
        let name = header.entry().filename.to_string_lossy().into_owned();
        archive = if header.entry().is_file() && image_ext(&name).is_some() {
            let (data, rest) = header.read().map_err(|e| e.to_string())?;
            into.keep(pages, &name, &mut data.as_slice())?;
            rest
        } else {
            header.skip().map_err(|e| e.to_string())?
        };
    }
    Ok(())
}

fn open(path: &Path, dir: &Path, id: u64) -> Result<Value, String> {
    let meta = fs::metadata(path).map_err(|e| e.to_string())?;
    let modified = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let format = match ext.as_str() {
        "cbz" | "zip" => "cbz",
        "cbr" | "rar" => "cbr",
        "cb7" | "7z" => "cb7",
        "epub" => "epub",
        _ => return Err(format!("La Estantería no abre archivos .{ext} de este PC (sí cbz, cbr, cb7 y epub)")),
    };
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
    let title = path.file_stem().and_then(|n| n.to_str()).unwrap_or(&name).to_string();
    let _ = fs::remove_dir_all(dir);         // something cut short before
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;

    let mut page_sizes: Vec<Value> = vec![];
    let mut pages = 0usize;
    let mut cover = false;
    if format == "epub" {
        fs::copy(path, dir.join("file.epub")).map_err(|e| e.to_string())?;
    } else {
        let pages_dir = dir.join("p");
        fs::create_dir_all(&pages_dir).map_err(|e| e.to_string())?;
        let mut unpacked = Unpacked { names: vec![] };
        let outcome = match format {
            "cbz" => unpack_zip(path, &pages_dir, &mut unpacked),
            "cb7" => unpack_7z(path, &pages_dir, &mut unpacked),
            _ => unpack_rar(path, &pages_dir, &mut unpacked),
        };
        // a .cbz that is a rar inside (or the other way round) is common: try the other kind
        let outcome = match (outcome, format) {
            (Err(_), "cbz") if unpacked.names.is_empty() => unpack_rar(path, &pages_dir, &mut unpacked),
            (Err(_), "cbr") if unpacked.names.is_empty() => unpack_zip(path, &pages_dir, &mut unpacked),
            (other, _) => other,
        };
        outcome?;
        if unpacked.names.is_empty() {
            return Err("no tiene imágenes".into());
        }
        unpacked.names.sort_by(|a, b| natural(&a.0, &b.0));
        for (n, (_, ext, tmp)) in unpacked.names.iter().enumerate() {
            let page = pages_dir.join(format!("{n}.{ext}"));
            fs::rename(tmp, &page).map_err(|e| e.to_string())?;
            let size = imagesize::size(&page).map(|s| json!([s.width, s.height])).unwrap_or(json!([0, 0]));
            page_sizes.push(size);
        }
        pages = unpacked.names.len();
        let (_, ext, _) = &unpacked.names[0];
        cover = fs::copy(pages_dir.join(format!("0.{ext}")), dir.join(format!("cover.{ext}"))).is_ok();
        if page_sizes.iter().any(|s| s == &json!([0, 0])) {
            page_sizes.clear();               // unknown sizes: the viewer measures them as it loads them
        }
    }

    let now = std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let item = json!({
        "id": id, "source_id": null, "path": path.to_string_lossy(), "folder": "", "name": name,
        "format": format, "kind": if format == "epub" { "book" } else { "comic" },
        "size": meta.len(), "modified": modified, "title": title, "series": null, "number": null,
        "author": null, "year": null, "summary": null, "pages": pages, "direction": "ltr", "cover": cover,
        "state": "ready", "error": null, "added": now, "updated": now, "meta": { "local": true },
        "progress": null, "page_sizes": page_sizes, "bookmarks": [],
    });
    let bytes: u64 = walk_size(dir);
    let entry = json!({ "item": item, "width": 0, "added": now, "bytes": bytes });
    fs::write(dir.join("item.json"), serde_json::to_vec(&entry).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    Ok(entry)
}

fn walk_size(dir: &Path) -> u64 {
    fs::read_dir(dir).map(|entries| entries.flatten().map(|e| {
        let p = e.path();
        if p.is_dir() { walk_size(&p) } else { e.metadata().map(|m| m.len()).unwrap_or(0) }
    }).sum()).unwrap_or(0)
}

/// Opens a file of this computer as an item kept offline (unpacked the first time); its entry.
#[tauri::command]
pub async fn local_open<R: Runtime>(app: AppHandle<R>, account: String, path: String) -> Result<Value, String> {
    let file = PathBuf::from(&path);
    let meta = fs::metadata(&file).map_err(|e| format!("no se encuentra el archivo ({e})"))?;
    let modified = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    let canonical = fs::canonicalize(&file).unwrap_or(file.clone());
    let key = format!("{}|{}|{}", canonical.to_string_lossy().to_lowercase(), meta.len(), modified);
    let id = LOCAL_BASE + (fnv(key.as_bytes()) & ((1 << 40) - 1));
    let dir = crate::offline::item_dir(&app, &account, id)?;
    if let Ok(data) = fs::read(dir.join("item.json")) {
        if let Ok(entry) = serde_json::from_slice::<Value>(&data) {
            return Ok(entry);
        }
    }
    tauri::async_runtime::spawn_blocking(move || {
        let outcome = open(&file, &dir, id);
        if outcome.is_err() {
            let _ = fs::remove_dir_all(&dir);
        }
        outcome
    }).await.map_err(|e| e.to_string())?
}

/// Brings the window to the front (a second launch of the app, with a file to open).
pub fn focus<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
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
    fn unpacks_a_cbz() {
        let tmp = std::env::temp_dir().join(format!("estanteria-local-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        let cbz = tmp.join("Serie 01.cbz");
        {
            let mut zip = zip::ZipWriter::new(fs::File::create(&cbz).unwrap());
            let opts = zip::write::SimpleFileOptions::default();
            // 1x1 PNG
            let png: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 2, 0, 0, 0, 3, 8, 6, 0, 0, 0, 0x9D, 0x74, 0x66, 0x1A];
            for name in ["10.png", "2.png", "ComicInfo.xml", "1.png"] {
                use std::io::Write;
                zip.start_file(name, opts).unwrap();
                zip.write_all(png).unwrap();
            }
            zip.finish().unwrap();
        }
        let dir = tmp.join("out");
        let entry = open(&cbz, &dir, LOCAL_BASE + 1).unwrap();
        assert_eq!(entry["item"]["pages"], 3);
        assert_eq!(entry["item"]["title"], "Serie 01");
        assert_eq!(entry["item"]["page_sizes"][0], json!([2, 3]));
        assert!(dir.join("p/2.png").is_file() && dir.join("cover.png").is_file() && dir.join("item.json").is_file());
        let _ = fs::remove_dir_all(&tmp);
    }
}
