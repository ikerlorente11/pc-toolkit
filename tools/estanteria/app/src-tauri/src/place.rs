//! Where the downloads go: one folder, `Descargas\La Estantería` until the person chooses another in the
//! settings. In it, what comes from the catalogs (`ONE PIECE/ONE PIECE - #001….cbz`) and the copies kept for
//! reading without connection, under their library's name (`EL archivador/Comics/Korra/Korra 01.pdf`, see
//! offline.rs). What only the app needs of those copies stays in its local data (`offline/`), so changing the
//! folder moves only what a person sees. The choice is kept in the app's local data (`downloads.json`).

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use tauri::{AppHandle, Manager, Runtime, State};

/// The folder chosen, once read (`None` inside: none chosen).
static CHOSEN: Mutex<Option<Option<PathBuf>>> = Mutex::new(None);

fn config<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    Ok(app.path().app_local_data_dir().map_err(|e| e.to_string())?.join("downloads.json"))
}

/// The folder the person chose, if any.
pub fn chosen<R: Runtime>(app: &AppHandle<R>) -> Option<PathBuf> {
    let mut cached = CHOSEN.lock().unwrap();
    if cached.is_none() {
        let read = config(app).ok()
            .and_then(|p| fs::read(p).ok())
            .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
            .and_then(|v| v.get("dir").and_then(|d| d.as_str()).map(PathBuf::from))
            .filter(|p| !p.as_os_str().is_empty());
        *cached = Some(read);
    }
    cached.clone().flatten()
}

fn usual<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    match app.path().download_dir() {
        Ok(dir) => Ok(dir.join("La Estantería")),
        Err(_) => Ok(app.path().app_local_data_dir().map_err(|e| e.to_string())?.join("Descargas")),
    }
}

/// The downloads folder: the catalogs' files and the copies kept offline.
pub fn catalogs_dir<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    match chosen(app) {
        Some(dir) => Ok(dir),
        None => usual(app),
    }
}

/// What the app keeps of each copy for reading offline (item.json, cover, pages made here): its local data.
pub fn offline_dir<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    Ok(app.path().app_local_data_dir().map_err(|e| e.to_string())?.join("offline"))
}

/// A path as the shelf keeps it (canonical, without the `\\?\` Windows adds).
fn canonical(path: &Path) -> String {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf()).to_string_lossy().trim_start_matches(r"\\?\").to_string()
}

/// Tells the shelf where the downloads folder is (its files keep their ids wherever it goes, see local::id_of).
fn tell_shelf(dir: &Path) {
    let _ = fs::create_dir_all(dir);
    *crate::local::DOWNLOADS.lock().unwrap() = Some(canonical(dir).to_lowercase());
}

/// At start: before the shelf lists anything.
pub fn init<R: Runtime>(app: &AppHandle<R>) {
    if let Ok(dir) = catalogs_dir(app) {
        tell_shelf(&dir);
    }
}

/// Moves what is inside `from` into `to`: each entry renamed there (on the same drive), else copied and then
/// deleted; a folder that is in both is merged, a file that is in both keeps the one already there.
fn merge(from: &Path, to: &Path) -> Result<(), String> {
    fs::create_dir_all(to).map_err(|e| e.to_string())?;
    for entry in fs::read_dir(from).map_err(|e| e.to_string())?.flatten() {
        let (src, dest) = (entry.path(), to.join(entry.file_name()));
        if src.is_dir() {
            if !dest.exists() && fs::rename(&src, &dest).is_ok() {
                continue;
            }
            merge(&src, &dest)?;
            let _ = fs::remove_dir(&src);
        } else if !dest.exists() {
            if fs::rename(&src, &dest).is_err() {
                fs::copy(&src, &dest).map_err(|e| format!("{}: {e}", src.display()))?;
                fs::remove_file(&src).map_err(|e| format!("{} (¿está abierto?): {e}", src.display()))?;
            }
        }
    }
    Ok(())
}

/// Sets the downloads folder (an empty `path`: back to the usual one) and moves there everything the old one
/// had: the catalogs' files and the copies kept offline. Not while a download goes on. Answers the folder now.
#[tauri::command]
pub async fn downloads_set_dir<R: Runtime>(app: AppHandle<R>, jobs: State<'_, crate::offline::Jobs>, path: String) -> Result<String, String> {
    if jobs.busy() {
        return Err("Espera a que acaben las descargas en curso (o páralas) para cambiar la carpeta.".into());
    }
    let new = PathBuf::from(path.trim());
    let new = if new.as_os_str().is_empty() { None } else { Some(new) };
    if new.as_ref().is_some_and(|p| !p.is_absolute()) {
        return Err(r"Esa carpeta no es una ruta completa (como C:\Users\…).".into());
    }
    let app2 = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let before = catalogs_dir(&app2)?;
        let after = match &new {
            Some(dir) => dir.clone(),
            None => usual(&app2)?,
        };
        fs::create_dir_all(&after).map_err(|e| format!("no se puede usar esa carpeta ({e})"))?;
        let (from, to) = (canonical(&before), canonical(&after));
        if from.to_lowercase() != to.to_lowercase() {
            if to.to_lowercase().starts_with(&format!("{}\\", from.to_lowercase())) {
                return Err("La carpeta nueva no puede estar dentro de la de ahora.".to_string());
            }
            if before.is_dir() {
                merge(&before, &after).map_err(|e| format!("no se pudo mover todo ({e})"))?;
                let _ = fs::remove_dir(&before);
            }
            crate::local::relocate(&app2, &from, &to)?;
        }
        let body = serde_json::json!({ "dir": new.as_ref().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default() });
        let file = config(&app2)?;
        if let Some(parent) = file.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        fs::write(&file, serde_json::to_vec(&body).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        *CHOSEN.lock().unwrap() = Some(new);
        tell_shelf(&after);
        Ok(after.to_string_lossy().into_owned())
    }).await.map_err(|e| e.to_string())?
}
