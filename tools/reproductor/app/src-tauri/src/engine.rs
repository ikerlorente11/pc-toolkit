//! The download engine: soundlift itself, frozen for Windows (soundlift's packaging/motor), so the app downloads
//! music by itself and no server does the work for people who have none. It is not in the installer: the first
//! time it is wanted it is downloaded from the releases `motor-v*` of the public repo ikerlorente11/reproductor into
//! `<app data>/motor/<tag>/`, and from then on it is started on demand on a free loopback port and ends with the app
//! (it also watches the app's process: SOUNDLIFT_PARENT_PID).
//!
//! The engine carries the El Reproductor service too (in its local mode): started with a second port, the app is
//! El Reproductor as on the server — search the catalogue, follow artists, download albums and songs, playlists —
//! with the music folder standing for the cloud's `/Música` (`MUSIC_ROOT`). Its key (`token`) is made at each start
//! and only the app knows it, so no other program of the computer can use the service.
//!
//! YouTube changes often and yt-dlp with it: the engine takes a newer yt-dlp if it finds one (its zipapp, the
//! release asset `yt-dlp` of yt-dlp/yt-dlp, kept in `<app data>/motor/yt-dlp`), so it stays working without a
//! new engine. The music goes to a folder the user picks (by default `Música\El Reproductor`).

use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, Runtime, State};

const RELEASES: &str = "https://api.github.com/repos/ikerlorente11/reproductor/releases?per_page=30";
const YTDLP_LATEST: &str = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest";
const EXE: &str = "soundlift-motor.exe";
/// the cloud's music folder as the El Reproductor service names it: here, the music folder of the engine
pub const MUSIC_ROOT: &str = "Música";
/// a newer yt-dlp is looked for at most this often
const YTDLP_EVERY: Duration = Duration::from_secs(3 * 24 * 3600);

/// The engine running: soundlift's port, the El Reproductor service's and its key.
#[derive(Clone, Serialize)]
pub struct Running {
    port: u16,
    rp_port: u16,
    token: String,
}

#[derive(Default)]
pub struct Engine {
    running: Mutex<Option<(Child, Running)>>,
    /// one install at a time
    installing: Mutex<()>,
}

#[derive(Default, Serialize, Deserialize, Clone)]
struct Config {
    /// the release installed (motor-v…)
    tag: Option<String>,
    /// where the music goes; empty: the default
    music_dir: Option<String>,
    /// when a newer yt-dlp was last looked for (seconds since 1970) and the one there is
    ytdlp_checked: Option<u64>,
    ytdlp: Option<String>,
}

#[derive(Serialize)]
pub struct Status {
    installed: Option<String>,
    /// what the installed engine carries (motor.json: soundlift, yt-dlp, built)
    info: Option<serde_json::Value>,
    /// a newer yt-dlp in use, if any
    ytdlp: Option<String>,
    running: Option<Running>,
    music_dir: String,
}

#[derive(Serialize, Clone)]
struct Progress {
    done: u64,
    total: u64,
}

#[derive(Serialize)]
pub struct Latest {
    tag: String,
    url: String,
    size: u64,
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn dir<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    Ok(app.path().app_local_data_dir().map_err(|e| e.to_string())?.join("motor"))
}

fn config<R: Runtime>(app: &AppHandle<R>) -> Config {
    dir(app).ok().and_then(|d| fs::read(d.join("motor.json")).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save_config<R: Runtime>(app: &AppHandle<R>, c: &Config) -> Result<(), String> {
    let d = dir(app)?;
    fs::create_dir_all(&d).map_err(|e| e.to_string())?;
    fs::write(d.join("motor.json"), serde_json::to_vec_pretty(c).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

/// Where downloaded music goes: the chosen folder, or «El Reproductor» inside Windows' Music folder.
fn music_dir<R: Runtime>(app: &AppHandle<R>, c: &Config) -> PathBuf {
    match c.music_dir.as_deref().filter(|s| !s.is_empty()) {
        Some(d) => PathBuf::from(d),
        None => app.path().audio_dir().unwrap_or_else(|_| PathBuf::from(".")).join("El Reproductor"),
    }
}

fn installed_exe<R: Runtime>(app: &AppHandle<R>, c: &Config) -> Option<PathBuf> {
    let exe = dir(app).ok()?.join(c.tag.as_deref()?).join(EXE);
    exe.is_file().then_some(exe)
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(15)).timeout_read(Duration::from_secs(60)).build()
}

fn get_json(url: &str) -> Result<serde_json::Value, String> {
    agent()
        .get(url)
        .set("User-Agent", "El-Reproductor")
        .set("Accept", "application/vnd.github+json")
        .call()
        .map_err(|e| format!("no se pudo consultar GitHub ({e})"))?
        .into_json()
        .map_err(|e| e.to_string())
}

fn is_running(engine: &Engine) -> Option<Running> {
    let mut guard = engine.running.lock().unwrap();
    if let Some((child, running)) = guard.as_mut() {
        if matches!(child.try_wait(), Ok(None)) {
            return Some(running.clone());
        }
        *guard = None; // it ended on its own
    }
    None
}

#[tauri::command]
pub fn motor_status<R: Runtime>(app: AppHandle<R>, engine: State<'_, Engine>) -> Status {
    let c = config(&app);
    let exe = installed_exe(&app, &c);
    let info = exe
        .as_ref()
        .and_then(|e| fs::read(e.with_file_name("motor.json")).ok())
        .and_then(|b| serde_json::from_slice(b.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&b)).ok());
    let ytdlp = dir(&app).ok().filter(|d| d.join("yt-dlp").is_file()).and(c.ytdlp.clone());
    Status {
        installed: exe.and(c.tag.clone()),
        info,
        ytdlp,
        running: is_running(&engine),
        music_dir: music_dir(&app, &c).to_string_lossy().into_owned(),
    }
}

/// The newest engine published (the first release `motor-v*` with its zip).
#[tauri::command]
pub async fn motor_latest() -> Result<Latest, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let releases = get_json(RELEASES)?;
        for r in releases.as_array().into_iter().flatten() {
            let tag = r["tag_name"].as_str().unwrap_or_default();
            if !tag.starts_with("motor-v") || r["draft"].as_bool() == Some(true) {
                continue;
            }
            if let Some(a) = r["assets"].as_array().into_iter().flatten().find(|a| a["name"].as_str().is_some_and(|n| n.ends_with("win-x64.zip"))) {
                return Ok(Latest { tag: tag.into(), url: a["browser_download_url"].as_str().unwrap_or_default().into(), size: a["size"].as_u64().unwrap_or(0) });
            }
        }
        Err("todavía no hay ningún motor de descargas publicado".into())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Downloads `url` into `file`, telling how far on `event`.
fn download<R: Runtime>(app: &AppHandle<R>, url: &str, file: &Path, event: &str) -> Result<(), String> {
    let res = agent().get(url).set("User-Agent", "El-Reproductor").call().map_err(|e| format!("no se pudo descargar ({e})"))?;
    let total: u64 = res.header("Content-Length").and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut body = res.into_reader();
    let mut out = fs::File::create(file).map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; 1 << 16];
    let (mut done, mut told) = (0u64, Instant::now());
    loop {
        let n = body.read(&mut buf).map_err(|e| format!("la descarga se cortó ({e})"))?;
        if n == 0 {
            break;
        }
        out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        done += n as u64;
        if told.elapsed() > Duration::from_millis(250) {
            let _ = app.emit(event, Progress { done, total });
            told = Instant::now();
        }
    }
    let _ = app.emit(event, Progress { done, total: total.max(done) });
    Ok(())
}

fn unzip(zip: &Path, to: &Path) -> Result<(), String> {
    let mut archive = zip::ZipArchive::new(fs::File::open(zip).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let Some(name) = entry.enclosed_name() else { continue };
        let target = to.join(name);
        if entry.is_dir() {
            fs::create_dir_all(&target).map_err(|e| e.to_string())?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let mut out = fs::File::create(&target).map_err(|e| e.to_string())?;
        std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Installs the newest engine (or updates it): download, unpack beside the old one, switch, remove the old.
#[tauri::command]
pub async fn motor_install<R: Runtime>(app: AppHandle<R>) -> Result<String, String> {
    let latest = motor_latest().await?;
    tauri::async_runtime::spawn_blocking(move || {
        let engine = app.state::<Engine>();
        let _one = engine.installing.try_lock().map_err(|_| "ya se está instalando".to_string())?;
        let mut c = config(&app);
        if c.tag.as_deref() == Some(latest.tag.as_str()) && installed_exe(&app, &c).is_some() {
            return Ok(latest.tag);
        }
        let d = dir(&app)?;
        fs::create_dir_all(&d).map_err(|e| e.to_string())?;
        let zip = d.join(format!("{}.zip", latest.tag));
        download(&app, &latest.url, &zip, "motor-progress")?;
        let fresh = d.join(&latest.tag);
        let _ = fs::remove_dir_all(&fresh);
        let unpacked = unzip(&zip, &fresh);
        let _ = fs::remove_file(&zip);
        unpacked?;
        if !fresh.join(EXE).is_file() {
            return Err("el motor descargado no trae su ejecutable".into());
        }
        let old = c.tag.replace(latest.tag.clone());
        save_config(&app, &c)?;
        if let Some(old) = old.filter(|o| o != &latest.tag) {
            stop(&engine);
            let _ = fs::remove_dir_all(d.join(old));
        }
        Ok(latest.tag)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Looks for a newer yt-dlp (every few days, or now with `force`) and keeps it for the next start.
#[tauri::command]
pub async fn motor_update_ytdlp<R: Runtime>(app: AppHandle<R>, force: bool) -> Result<Option<String>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut c = config(&app);
        let d = dir(&app)?;
        if !force && c.ytdlp_checked.is_some_and(|t| now().saturating_sub(t) < YTDLP_EVERY.as_secs()) {
            return Ok(c.ytdlp.clone());
        }
        let latest = get_json(YTDLP_LATEST)?;
        let version = latest["tag_name"].as_str().unwrap_or_default().to_string();
        c.ytdlp_checked = Some(now());
        if c.ytdlp.as_deref() != Some(version.as_str()) || !d.join("yt-dlp").is_file() {
            let asset = latest["assets"].as_array().into_iter().flatten().find(|a| a["name"].as_str() == Some("yt-dlp"))
                .ok_or("yt-dlp no publica su zipapp")?;
            let url = asset["browser_download_url"].as_str().unwrap_or_default().to_string();
            fs::create_dir_all(&d).map_err(|e| e.to_string())?;
            let tmp = d.join("yt-dlp.part");
            download(&app, &url, &tmp, "motor-ytdlp-progress")?;
            fs::rename(&tmp, d.join("yt-dlp")).map_err(|e| e.to_string())?;
            c.ytdlp = Some(version);
        }
        save_config(&app, &c)?;
        Ok(c.ytdlp.clone())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn motor_set_music_dir<R: Runtime>(app: AppHandle<R>, engine: State<'_, Engine>, path: Option<String>) -> Result<String, String> {
    let mut c = config(&app);
    c.music_dir = path.filter(|p| !p.is_empty());
    save_config(&app, &c)?;
    stop(&engine); // the next start takes the new folder
    Ok(music_dir(&app, &c).to_string_lossy().into_owned())
}

fn free_port() -> Result<u16, String> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    Ok(listener.local_addr().map_err(|e| e.to_string())?.port())
}

/// A key nobody can guess, made at each start (the standard library's random hasher keys, 128 bits).
fn new_token() -> String {
    use std::hash::{BuildHasher, Hasher};
    (0..2u64)
        .map(|i| {
            let mut h = std::collections::hash_map::RandomState::new().build_hasher();
            h.write_u64(now() ^ i);
            format!("{:016x}", h.finish())
        })
        .collect()
}

/// Starts the engine (if it is not running yet) and waits until both its services answer.
#[tauri::command]
pub async fn motor_start<R: Runtime>(app: AppHandle<R>) -> Result<Running, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let engine = app.state::<Engine>();
        if let Some(running) = is_running(&engine) {
            return Ok(running);
        }
        let c = config(&app);
        let exe = installed_exe(&app, &c).ok_or("el motor de descargas no está instalado")?;
        let d = dir(&app)?;
        let music = music_dir(&app, &c);
        fs::create_dir_all(&music).map_err(|e| format!("no se pudo crear la carpeta de la música ({e})"))?;
        let data = d.join("data");
        fs::create_dir_all(&data).map_err(|e| e.to_string())?;
        let port = free_port()?;
        let mut rp_port = free_port()?;
        while rp_port == port {
            rp_port = free_port()?;
        }
        let token = new_token();
        let rp_data = data.join("reproductor");
        fs::create_dir_all(&rp_data).map_err(|e| e.to_string())?;
        let log = fs::File::create(d.join("motor.log")).map_err(|e| e.to_string())?;
        let mut cmd = Command::new(&exe);
        cmd.args(["serve", "--host", "127.0.0.1", "--port", &port.to_string()])
            .current_dir(&d)
            .env("SOUNDLIFT_LIBRARY_DIR", &music)
            .env("SOUNDLIFT_DATA_DIR", &data)
            .env("SOUNDLIFT_CONFIG_FILE", d.join("config.toml"))
            .env("SOUNDLIFT_PARENT_PID", std::process::id().to_string())
            .env("PYTHONIOENCODING", "utf-8")
            // the El Reproductor service, in its local mode (see the module's docstring)
            .env("MOTOR_REPRODUCTOR_PORT", rp_port.to_string())
            .env("REPRODUCTOR_LOCAL_DIR", &music)
            .env("REPRODUCTOR_LOCAL_TOKEN", &token)
            .env("REPRODUCTOR_MUSIC_ROOT", MUSIC_ROOT)
            .env("REPRODUCTOR_DATA_DIR", &rp_data)
            .env("REPRODUCTOR_SOUNDLIFT_URL", format!("http://127.0.0.1:{port}"))
            .stdin(Stdio::null())
            .stdout(log.try_clone().map_err(|e| e.to_string())?)
            .stderr(log);
        let ytdlp = d.join("yt-dlp");
        if ytdlp.is_file() {
            cmd.env("SOUNDLIFT_YTDLP", &ytdlp);
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = cmd.spawn().map_err(|e| format!("no se pudo arrancar el motor ({e})"))?;
        let started = Instant::now();
        let infos = [format!("http://127.0.0.1:{port}/api/info"), format!("http://127.0.0.1:{rp_port}/api/info")];
        loop {
            if let Ok(Some(status)) = child.try_wait() {
                return Err(format!("el motor se cerró al arrancar ({status}); mira {}", d.join("motor.log").display()));
            }
            if infos.iter().all(|u| agent().get(u).timeout(Duration::from_secs(2)).call().is_ok()) {
                break;
            }
            if started.elapsed() > Duration::from_secs(60) {
                let _ = child.kill();
                return Err("el motor no responde".into());
            }
            std::thread::sleep(Duration::from_millis(300));
        }
        let running = Running { port, rp_port, token };
        *engine.running.lock().unwrap() = Some((child, running.clone()));
        Ok(running)
    })
    .await
    .map_err(|e| e.to_string())?
}

pub fn stop(engine: &Engine) {
    if let Some((mut child, _)) = engine.running.lock().unwrap().take() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[tauri::command]
pub fn motor_stop(engine: State<'_, Engine>) {
    stop(&engine);
}

/// Opens the folder where the downloaded music goes.
#[tauri::command]
pub fn motor_open_music_dir<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let path = music_dir(&app, &config(&app));
    fs::create_dir_all(&path).map_err(|e| e.to_string())?;
    #[cfg(windows)]
    std::process::Command::new("explorer").arg(&path).spawn().map_err(|e| e.to_string())?;
    Ok(())
}

// ---- the music folder, by the paths the El Reproductor service gives (/Música/…) ----

/// A path of the service (`/Música/Artistas/…`, or `Música/…`) as a file or folder of the music folder; never outside.
pub fn music_path<R: Runtime>(app: &AppHandle<R>, path: &str) -> Option<PathBuf> {
    let rest = path.trim_start_matches('/');
    let rest = if rest == MUSIC_ROOT { "" } else { rest.strip_prefix(MUSIC_ROOT)?.strip_prefix('/')? };
    let mut out = music_dir(app, &config(app));
    for part in rest.split('/').filter(|p| !p.is_empty()) {
        if part == ".." || part == "." || part.contains(['\\', ':']) {
            return None;
        }
        out.push(part);
    }
    Some(out)
}

#[derive(Serialize)]
pub struct Entry {
    path: String,
    name: String,
    size: u64,
}

#[derive(Serialize)]
pub struct Listing {
    folders: Vec<Entry>,
    files: Vec<Entry>,
}

/// What is right inside a folder of the music (by the service's path), as the pages list it ("404": not there).
#[tauri::command]
pub fn music_list<R: Runtime>(app: AppHandle<R>, dir: String) -> Result<Listing, String> {
    let folder = music_path(&app, &dir).ok_or("fuera de la música")?;
    let base = format!("/{}", dir.trim_matches('/'));
    let mut out = Listing { folders: vec![], files: vec![] };
    let entries = fs::read_dir(&folder).map_err(|e| if e.kind() == std::io::ErrorKind::NotFound { "404".to_string() } else { e.to_string() })?;
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name.starts_with('$') {
            continue;
        }
        let Ok(meta) = e.metadata() else { continue };
        let entry = Entry { path: format!("{base}/{name}"), name, size: meta.len() };
        if meta.is_dir() {
            out.folders.push(entry)
        } else {
            out.files.push(entry)
        }
    }
    Ok(out)
}

/// To the recycle bin: a song or a folder of the music (the pages delete as in the cloud: to its bin). "404": not there.
#[tauri::command]
pub fn music_remove<R: Runtime>(app: AppHandle<R>, path: String) -> Result<(), String> {
    let target = music_path(&app, &path).ok_or("fuera de la música")?;
    if target == music_dir(&app, &config(&app)) {
        return Err("la carpeta de la música no se borra".into());
    }
    if !target.exists() {
        return Err("404".into());
    }
    trash::delete(&target).map_err(|e| e.to_string())
}
