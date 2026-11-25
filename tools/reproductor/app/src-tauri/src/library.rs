//! The music of this computer: the folders the user chose (by default, Windows' Music folder), every audio
//! file in them read once for its tags (lofty) and kept in an index in the app's data folder
//! (`library.json`), so the next start is instant and a new scan only reads what changed (by size and date).
//!
//! The web view reaches the files through the `media` protocol (`http://media.localhost/` on Windows):
//! - `/f/<id>`: the audio file, whole or the piece a `Range` asks (the audio element seeks with ranges);
//! - `/c/<cover>`: an album's cover, taken once from the songs' tags or a picture in their folder.
//!
//! A track's id is a hash of its path, so it stays the same between scans and runs.

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::UNIX_EPOCH;

use lofty::file::{AudioFile, TaggedFileExt};
use lofty::tag::{Accessor, ItemKey};
use serde::{Deserialize, Serialize};
use tauri::http::{Request, Response};
use tauri::{AppHandle, Emitter, Manager, Runtime, State, UriSchemeContext, UriSchemeResponder};

/// Audio the web view (Chromium) plays: what is not here is left out of the library.
pub const AUDIO: &[&str] = &["mp3", "flac", "opus", "ogg", "oga", "m4a", "aac", "wav", "webm", "mp4"];
/// Pictures in an album's folder taken as its cover, in this order.
const FOLDER_COVERS: &[&str] = &["cover", "folder", "front", "album", "albumart"];
/// A ranged answer is at most this long (the audio element asks again for the rest).
const RANGE_PIECE: u64 = 4 << 20;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Track {
    pub id: String,
    pub path: String,
    pub size: u64,
    /// last modification, seconds since 1970
    pub mtime: u64,
    pub title: String,
    pub artist: String,
    /// the album's artist as tagged (a compilation's: «Varios artistas»); empty when the tags do not say
    pub album_artist: String,
    pub album: String,
    pub track: u32,
    pub disc: u32,
    pub year: u32,
    pub genre: String,
    /// seconds
    pub duration: f64,
    /// the cover's id in `/c/` (shared by the album's songs), if any
    pub cover: Option<String>,
    /// when it came into the library (seconds since 1970): what «Añadido hace poco» sorts by
    #[serde(default)]
    pub added: u64,
}

#[derive(Default, Serialize, Deserialize)]
struct Index {
    roots: Vec<String>,
    tracks: Vec<Track>,
    /// the roots were set by the user (else the Music folder is used the first time)
    #[serde(default)]
    chosen: bool,
}

#[derive(Default)]
pub struct Library {
    index: Mutex<Option<Index>>,
    /// files opened from the Explorer, outside the library's folders: playable too
    extra: Mutex<HashMap<String, PathBuf>>,
    scanning: Arc<AtomicBool>,
}

#[derive(Serialize)]
pub struct Snapshot {
    roots: Vec<String>,
    tracks: Vec<Track>,
    scanning: bool,
}

#[derive(Clone, Serialize)]
struct Progress {
    done: usize,
    total: usize,
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub fn fnv(data: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in data {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// The id of a file: the hash of its path written the same way every time (case too, as Windows ignores it).
pub fn id_of(path: &Path) -> String {
    format!("{:016x}", fnv(path.to_string_lossy().to_lowercase().as_bytes()))
}

fn data_dir<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    app.path().app_local_data_dir().map_err(|e| e.to_string())
}

fn index_file<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    Ok(data_dir(app)?.join("library.json"))
}

fn covers_dir<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    Ok(data_dir(app)?.join("covers"))
}

/// `path` is `root` or something inside it (case aside, as on Windows; «C:\Música2» is not inside «C:\Música»).
fn under(path: &str, root: &str) -> bool {
    let (p, r) = (path.to_lowercase().replace('/', "\\"), root.to_lowercase().replace('/', "\\"));
    let r = r.trim_end_matches('\\');
    p == r || p.strip_prefix(r).is_some_and(|rest| rest.starts_with('\\'))
}

fn is_audio(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()).is_some_and(|e| AUDIO.contains(&e.to_ascii_lowercase().as_str()))
}

fn load<R: Runtime>(app: &AppHandle<R>) -> Index {
    let mut index: Index = index_file(app)
        .ok()
        .and_then(|f| fs::read(f).ok())
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_default();
    if !index.chosen && index.roots.is_empty() {
        if let Ok(music) = app.path().audio_dir() {
            index.roots.push(music.to_string_lossy().into_owned());
        }
    }
    index
}

fn save<R: Runtime>(app: &AppHandle<R>, index: &Index) -> Result<(), String> {
    let file = index_file(app)?;
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = file.with_extension("json.tmp");
    fs::write(&tmp, serde_json::to_vec(index).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &file).map_err(|e| e.to_string())
}

fn with_index<R: Runtime, T>(app: &AppHandle<R>, lib: &Library, f: impl FnOnce(&mut Index) -> T) -> T {
    let mut guard = lib.index.lock().unwrap();
    let index = guard.get_or_insert_with(|| load(app));
    f(index)
}

/// Every audio file under `root` (hidden folders and `$RECYCLE.BIN` left out), with its size and date.
fn walk(root: &Path, out: &mut Vec<(PathBuf, u64, u64)>, stop: &AtomicBool) {
    let Ok(entries) = fs::read_dir(root) else { return };
    for entry in entries.flatten() {
        if stop.load(Ordering::Relaxed) {
            return;
        }
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            if !name.starts_with('.') && !name.starts_with('$') {
                walk(&path, out, stop);
            }
        } else if kind.is_file() && is_audio(&path) {
            if let Ok(meta) = entry.metadata() {
                let mtime = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
                out.push((path, meta.len(), mtime));
            }
        }
    }
}

/// "03 - Artista - Título" → ("Artista", "Título"); "Título" → ("", "Título"): for files without tags.
fn from_name(path: &Path) -> (String, String) {
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let parts: Vec<&str> = stem.split(" - ").collect();
    let parts: Vec<&str> = if parts.len() > 1 && parts[0].trim().chars().all(|c| c.is_ascii_digit()) { parts[1..].to_vec() } else { parts };
    match parts.as_slice() {
        [title] => (String::new(), title.trim().to_string()),
        [artist, rest @ ..] => (artist.trim().to_string(), rest.join(" - ").trim().to_string()),
        [] => (String::new(), stem),
    }
}

/// A picture in the song's folder that looks like the album's cover.
fn folder_cover(dir: &Path) -> Option<PathBuf> {
    let entries: Vec<PathBuf> = fs::read_dir(dir).ok()?.flatten().map(|e| e.path()).collect();
    for wanted in FOLDER_COVERS {
        for p in &entries {
            let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_ascii_lowercase();
            let ext = p.extension().and_then(|s| s.to_str()).unwrap_or("").to_ascii_lowercase();
            if stem == *wanted && matches!(ext.as_str(), "jpg" | "jpeg" | "png" | "webp") {
                return Some(p.clone());
            }
        }
    }
    None
}

/// Reads one file's tags; its cover (the front picture, else the first) is written once per album.
fn read_track(path: &Path, size: u64, mtime: u64, covers: &Path, done_covers: &Mutex<HashSet<String>>) -> Track {
    let id = id_of(path);
    let (name_artist, name_title) = from_name(path);
    let folder = path.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let mut t = Track { id, path: path.to_string_lossy().into_owned(), size, mtime, ..Default::default() };
    let mut picture: Option<(Vec<u8>, &'static str)> = None;
    if let Ok(tagged) = lofty::read_from_path(path) {
        t.duration = tagged.properties().duration().as_secs_f64();
        if let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) {
            t.title = tag.title().map(|s| s.trim().to_string()).unwrap_or_default();
            t.artist = tag.artist().map(|s| s.trim().to_string()).unwrap_or_default();
            t.album = tag.album().map(|s| s.trim().to_string()).unwrap_or_default();
            t.album_artist = tag.get_string(&ItemKey::AlbumArtist).map(|s| s.trim().to_string()).unwrap_or_default();
            t.genre = tag.genre().map(|s| s.trim().to_string()).unwrap_or_default();
            t.track = tag.track().unwrap_or(0);
            t.disc = tag.disk().unwrap_or(0);
            t.year = tag
                .get_string(&ItemKey::Year)
                .or_else(|| tag.get_string(&ItemKey::RecordingDate))
                .or_else(|| tag.get_string(&ItemKey::OriginalReleaseDate))
                .and_then(|d| d.get(..4)?.parse().ok())
                .unwrap_or(0);
            let pics = tag.pictures();
            let front = pics.iter().find(|p| p.pic_type() == lofty::picture::PictureType::CoverFront).or_else(|| pics.first());
            if let Some(p) = front {
                let mime = match p.mime_type() {
                    Some(lofty::picture::MimeType::Png) => "png",
                    Some(lofty::picture::MimeType::Gif) => "gif",
                    Some(lofty::picture::MimeType::Bmp) => "bmp",
                    _ => "jpg",
                };
                picture = Some((p.data().to_vec(), mime));
            }
        }
    }
    if t.title.is_empty() {
        t.title = name_title;
    }
    if t.artist.is_empty() {
        t.artist = name_artist;
    }
    if t.album.is_empty() {
        t.album = folder.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    }
    // One cover per album (its name + folder): the first song that has one gives it.
    let cover_id = format!("{:016x}", fnv(format!("{}\u{1}{}", t.album.to_lowercase(), folder.to_string_lossy().to_lowercase()).as_bytes()));
    let known = done_covers.lock().unwrap().contains(&cover_id);
    if known {
        t.cover = Some(cover_id);
    } else {
        let source = picture.or_else(|| {
            let file = folder_cover(&folder)?;
            let ext = file.extension()?.to_str()?.to_ascii_lowercase();
            let ext: &'static str = if ext == "png" { "png" } else if ext == "webp" { "webp" } else { "jpg" };
            Some((fs::read(file).ok()?, ext))
        });
        if let Some((data, ext)) = source {
            let file = covers.join(format!("{cover_id}.{ext}"));
            if file.exists() || fs::write(&file, &data).is_ok() {
                done_covers.lock().unwrap().insert(cover_id.clone());
                t.cover = Some(cover_id);
            }
        }
    }
    t
}

/// The cover files already written (their ids), so a rescan does not write them again.
fn known_covers(covers: &Path) -> HashSet<String> {
    fs::read_dir(covers)
        .map(|it| it.flatten().filter_map(|e| Some(e.path().file_stem()?.to_str()?.to_string())).collect())
        .unwrap_or_default()
}

/// Looks through the roots again: new and changed files are read, the rest kept as they were.
fn scan<R: Runtime>(app: AppHandle<R>, stop: Arc<AtomicBool>) -> Result<(), String> {
    let lib = app.state::<Library>();
    let (roots, old): (Vec<String>, HashMap<String, Track>) =
        with_index(&app, &lib, |i| (i.roots.clone(), i.tracks.iter().map(|t| (t.path.clone(), t.clone())).collect()));
    let mut found = vec![];
    for root in &roots {
        walk(Path::new(root), &mut found, &stop);
    }
    let covers = covers_dir(&app)?;
    fs::create_dir_all(&covers).map_err(|e| e.to_string())?;
    let done_covers = Mutex::new(known_covers(&covers));
    let total = found.len();
    let done = std::sync::atomic::AtomicUsize::new(0);
    let added = now();
    let first = old.is_empty();
    let tracks: Mutex<Vec<Track>> = Mutex::new(Vec::with_capacity(total));
    let next = std::sync::atomic::AtomicUsize::new(0);
    let workers = thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(2, 8);
    let _ = app.emit("library-progress", Progress { done: 0, total });
    thread::scope(|s| {
        for _ in 0..workers {
            s.spawn(|| loop {
                if stop.load(Ordering::Relaxed) {
                    return;
                }
                let i = next.fetch_add(1, Ordering::Relaxed);
                let Some((path, size, mtime)) = found.get(i) else { return };
                let key = path.to_string_lossy().into_owned();
                let track = match old.get(&key) {
                    Some(t) if t.size == *size && t.mtime == *mtime => t.clone(),
                    known => {
                        let mut t = read_track(path, *size, *mtime, &covers, &done_covers);
                        // the first time, everything arrives at once: the file's date says what is newer
                        let arrived = if first { *mtime } else { added };
                        t.added = known.map(|k| k.added).filter(|&a| a > 0).unwrap_or(arrived);
                        t
                    }
                };
                tracks.lock().unwrap().push(track);
                let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                if n % 200 == 0 {
                    let _ = app.emit("library-progress", Progress { done: n, total });
                }
            });
        }
    });
    if stop.load(Ordering::Relaxed) {
        return Ok(());
    }
    let mut tracks = tracks.into_inner().unwrap();
    tracks.sort_by(|a, b| a.path.cmp(&b.path));
    with_index(&app, &lib, |i| {
        // the roots may have changed meanwhile: keep only what is under the ones left
        tracks.retain(|t| i.roots.iter().any(|r| under(&t.path, r)));
        i.tracks = tracks;
        save(&app, i)
    })?;
    let _ = app.emit("library-progress", Progress { done: total, total });
    Ok(())
}

fn start_scan<R: Runtime>(app: &AppHandle<R>, lib: &Library) {
    if lib.scanning.swap(true, Ordering::SeqCst) {
        return; // one at a time; the one running picks up the roots as they are when it saves
    }
    let app = app.clone();
    let flag = lib.scanning.clone();
    thread::spawn(move || {
        let stop = Arc::new(AtomicBool::new(false));
        let result = scan(app.clone(), stop);
        flag.store(false, Ordering::SeqCst);
        let _ = app.emit("library-changed", result.err());
    });
}

#[tauri::command]
pub fn library_get<R: Runtime>(app: AppHandle<R>, lib: State<'_, Library>) -> Snapshot {
    let (roots, tracks) = with_index(&app, &lib, |i| (i.roots.clone(), i.tracks.clone()));
    Snapshot { roots, tracks, scanning: lib.scanning.load(Ordering::SeqCst) }
}

#[tauri::command]
pub fn library_scan<R: Runtime>(app: AppHandle<R>, lib: State<'_, Library>) {
    start_scan(&app, &lib);
}

#[tauri::command]
pub fn library_add_root<R: Runtime>(app: AppHandle<R>, lib: State<'_, Library>, path: String) -> Result<(), String> {
    let dir = PathBuf::from(&path);
    if !dir.is_dir() {
        return Err("esa carpeta no existe".into());
    }
    with_index(&app, &lib, |i| {
        // a folder inside one already there adds nothing; one that holds others takes their place
        if i.roots.iter().any(|r| under(&path, r)) {
            return Ok(());
        }
        i.roots.retain(|r| !under(r, &path));
        i.roots.push(path.clone());
        i.chosen = true;
        save(&app, i)
    })?;
    start_scan(&app, &lib);
    Ok(())
}

#[tauri::command]
pub fn library_remove_root<R: Runtime>(app: AppHandle<R>, lib: State<'_, Library>, path: String) -> Result<(), String> {
    with_index(&app, &lib, |i| {
        i.roots.retain(|r| r != &path);
        i.chosen = true;
        i.tracks.retain(|t| !under(&t.path, &path));
        save(&app, i)
    })?;
    let _ = app.emit("library-changed", Option::<String>::None);
    Ok(())
}

/// A file opened from the Explorer (or dropped on the window): read for the player, also outside the library.
#[tauri::command]
pub fn library_open_file<R: Runtime>(app: AppHandle<R>, lib: State<'_, Library>, path: String) -> Result<Track, String> {
    let file = PathBuf::from(&path);
    if !file.is_file() || !is_audio(&file) {
        return Err("no es un archivo de música que se pueda reproducir".into());
    }
    let id = id_of(&file);
    if let Some(t) = with_index(&app, &lib, |i| i.tracks.iter().find(|t| t.id == id).cloned()) {
        return Ok(t);
    }
    let meta = fs::metadata(&file).map_err(|e| e.to_string())?;
    let mtime = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    let covers = covers_dir(&app)?;
    fs::create_dir_all(&covers).map_err(|e| e.to_string())?;
    let done = Mutex::new(known_covers(&covers));
    let track = read_track(&file, meta.len(), mtime, &covers, &done);
    lib.extra.lock().unwrap().insert(track.id.clone(), file);
    Ok(track)
}

/// Shows a song's file in the Explorer, selected.
#[tauri::command]
pub fn library_reveal(path: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        std::process::Command::new("explorer").raw_arg(format!("/select,\"{path}\"")).spawn().map_err(|e| e.to_string())?;
    }
    #[cfg(not(windows))]
    {
        let dir = Path::new(&path).parent().map(|p| p.to_path_buf()).unwrap_or_default();
        std::process::Command::new("xdg-open").arg(dir).spawn().map_err(|e| e.to_string())?;
    }
    Ok(())
}

// ---- the media protocol ----

fn mime_of(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref() {
        Some("mp3") => "audio/mpeg",
        Some("flac") => "audio/flac",
        Some("opus") => "audio/ogg; codecs=opus",
        Some("ogg") | Some("oga") => "audio/ogg",
        Some("m4a") | Some("mp4") | Some("aac") => "audio/mp4",
        Some("wav") => "audio/wav",
        Some("webm") => "audio/webm",
        Some("lrc") => "text/plain; charset=utf-8",
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        Some("bmp") => "image/bmp",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        _ => "application/octet-stream",
    }
}

/// What a `Range` header asks of a file of `size` bytes, as `start..=end` (the first range it names, cut to
/// `RANGE_PIECE`); `None` when it cannot be served (416).
pub fn served_range(header: &str, size: u64) -> Option<(u64, u64)> {
    let (unit, ranges) = header.trim().split_once('=')?;
    if !unit.trim().eq_ignore_ascii_case("bytes") || size == 0 {
        return None;
    }
    let (from, to) = ranges.split(',').next()?.trim().split_once('-')?;
    let (from, to) = (from.trim(), to.trim());
    let (start, end) = if from.is_empty() {
        let last: u64 = to.parse().ok().filter(|&n| n > 0)?;
        (size.saturating_sub(last), size - 1)
    } else {
        let start: u64 = from.parse().ok()?;
        let end = if to.is_empty() { size - 1 } else { to.parse::<u64>().ok()?.min(size - 1) };
        (start, end)
    };
    if start >= size || end < start {
        return None;
    }
    Some((start, end.min(start.saturating_add(RANGE_PIECE - 1))))
}

/// A file of the disk, whole (200) or the piece a `Range` asks (206). A HEAD gets the headers only.
pub fn file_response(path: &Path, request: &Request<Vec<u8>>) -> Result<Response<Cow<'static, [u8]>>, String> {
    let mut file = fs::File::open(path).map_err(|e| format!("el archivo ya no está ({e})"))?;
    let size = file.metadata().map_err(|e| e.to_string())?.len();
    let builder = Response::builder()
        .header("Content-Type", mime_of(path))
        .header("Accept-Ranges", "bytes")
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Expose-Headers", "Content-Range")
        .header("Cache-Control", "private, max-age=600");
    let head = request.method() == tauri::http::Method::HEAD;
    let range = request.headers().get("range").and_then(|v| v.to_str().ok());
    let (builder, body) = match range {
        Some(asked) => {
            let Some((start, end)) = served_range(asked, size) else {
                return Ok(Response::builder()
                    .status(416)
                    .header("Content-Range", format!("bytes */{size}"))
                    .header("Access-Control-Allow-Origin", "*")
                    .header("Cache-Control", "no-store")
                    .body(Cow::Owned(vec![]))
                    .unwrap());
            };
            let mut body = vec![];
            if !head {
                file.seek(SeekFrom::Start(start)).map_err(|e| e.to_string())?;
                body.reserve((end + 1 - start) as usize);
                file.take(end + 1 - start).read_to_end(&mut body).map_err(|e| e.to_string())?;
            }
            let builder = builder.status(206).header("Content-Range", format!("bytes {start}-{end}/{size}")).header("Content-Length", end + 1 - start);
            (builder, body)
        }
        None => {
            let mut body = vec![];
            if !head {
                body.reserve(size as usize);
                file.read_to_end(&mut body).map_err(|e| e.to_string())?;
            }
            (builder.status(200).header("Content-Length", size), body)
        }
    };
    builder.body(Cow::Owned(body)).map_err(|e| e.to_string())
}

fn path_of<R: Runtime>(app: &AppHandle<R>, id: &str) -> Option<PathBuf> {
    let lib = app.state::<Library>();
    if let Some(p) = lib.extra.lock().unwrap().get(id) {
        return Some(p.clone());
    }
    with_index(app, &lib, |i| i.tracks.iter().find(|t| t.id == id).map(|t| PathBuf::from(&t.path)))
}

fn cover_file<R: Runtime>(app: &AppHandle<R>, id: &str) -> Option<PathBuf> {
    if !id.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let dir = covers_dir(app).ok()?;
    ["jpg", "png", "webp", "gif", "bmp"].iter().map(|ext| dir.join(format!("{id}.{ext}"))).find(|p| p.is_file())
}

fn answer<R: Runtime>(request: &Request<Vec<u8>>, app: &AppHandle<R>) -> Response<Cow<'static, [u8]>> {
    let missing = |why: String| {
        Response::builder()
            .status(404)
            .header("Content-Type", "text/plain; charset=utf-8")
            .header("Access-Control-Allow-Origin", "*")
            .header("Cache-Control", "no-store")
            .body(Cow::Owned(why.into_bytes()))
            .unwrap()
    };
    let path = request.uri().path().trim_matches('/').to_string();
    let found = match path.split_once('/') {
        Some(("f", id)) => path_of(app, id),
        Some(("c", id)) => cover_file(app, id),
        // a song of the engine's music folder, by the El Reproductor service's path (/m/Música/Artistas/…)
        Some(("m", rest)) => crate::engine::music_path(app, &percent_decode(rest)).filter(|p| p.is_file()),
        // the song's synced lyrics, when a .lrc with its name sits next to it
        Some(("l", id)) => path_of(app, id).map(|p| p.with_extension("lrc")).filter(|p| p.is_file()),
        _ => None,
    };
    match found {
        Some(file) => file_response(&file, request).unwrap_or_else(missing),
        None => missing("no existe".into()),
    }
}

/// `%C3%BA` → `ú`: the path of a URL as it was written.
fn percent_decode(text: &str) -> String {
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

/// The `media` protocol, answered away from the window's thread.
pub fn serve<R: Runtime>(ctx: UriSchemeContext<'_, R>, request: Request<Vec<u8>>, responder: UriSchemeResponder) {
    let app = ctx.app_handle().clone();
    thread::spawn(move || responder.respond(answer(&request, &app)));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_without_tags() {
        assert_eq!(from_name(Path::new("C:/m/03 - Artista - Título.mp3")), ("Artista".into(), "Título".into()));
        assert_eq!(from_name(Path::new("C:/m/Artista - Título - Remix.mp3")), ("Artista".into(), "Título - Remix".into()));
        assert_eq!(from_name(Path::new("C:/m/Título.flac")), ("".into(), "Título".into()));
        assert_eq!(from_name(Path::new("C:/m/07 - Título.flac")), ("".into(), "Título".into()));
    }

    #[test]
    fn ranges() {
        assert_eq!(served_range("bytes=0-99", 1000), Some((0, 99)));
        assert_eq!(served_range("bytes=990-", 1000), Some((990, 999)));
        assert_eq!(served_range("bytes=-10", 1000), Some((990, 999)));
        assert_eq!(served_range("bytes=1000-", 1000), None);
        assert_eq!(served_range("bytes=0-", 10 << 20), Some((0, RANGE_PIECE - 1)));
    }

    #[test]
    fn inside_a_folder() {
        assert!(under(r"C:\Música\a.mp3", r"C:\Música"));
        assert!(under(r"c:\música\x\a.mp3", r"C:\Música\"));
        assert!(under(r"C:\Música", r"C:\Música"));
        assert!(!under(r"C:\Música2\a.mp3", r"C:\Música"));
        assert!(under("C:/Música/a.mp3", r"C:\Música"));
    }

    #[test]
    fn urls_decoded() {
        assert_eq!(percent_decode("M%C3%BAsica/AC%2FDC%20x"), "Música/AC/DC x");
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("a%2"), "a%2");
    }

    #[test]
    fn ids_ignore_case() {
        assert_eq!(id_of(Path::new("C:/Música/a.mp3")), id_of(Path::new("c:/música/A.MP3")));
    }
}
