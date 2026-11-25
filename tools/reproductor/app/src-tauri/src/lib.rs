//! El Reproductor for the desktop: a Tauri shell around the shared app (reproductor-player). The Rust side
//! keeps the index of this computer's music and serves its songs and covers (see library.rs), and keeps the
//! user's app password in the operating system's credential store, and runs the download engine (soundlift, see
//! engine.rs); everything else happens in the web view.

mod cloud;
mod engine;
mod library;

use std::path::Path;

use tauri::{AppHandle, Emitter, Manager, Runtime, State};

/// The secrets' service in the credential store; the account is the server's user (its app password) or
/// `player:<key>` for the page's own secrets.
const SERVICE: &str = "El Reproductor";

#[tauri::command]
fn secret_get(account: String) -> Result<Option<String>, String> {
    let entry = keyring::Entry::new(SERVICE, &account).map_err(|e| e.to_string())?;
    match entry.get_password() {
        Ok(secret) => Ok(Some(secret)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
fn secret_set(account: String, secret: String) -> Result<(), String> {
    keyring::Entry::new(SERVICE, &account).and_then(|e| e.set_password(&secret)).map_err(|e| e.to_string())
}

#[tauri::command]
fn secret_delete(account: String) -> Result<(), String> {
    match keyring::Entry::new(SERVICE, &account).and_then(|e| e.delete_credential()) {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

/// The song the app was opened with (a double click in the Explorer), until the web view asks for it.
#[derive(Default)]
struct Launch(std::sync::Mutex<Option<String>>);

/// The first argument that is a song (Windows passes «%1» on a double click).
fn file_argument<I: IntoIterator<Item = String>>(args: I) -> Option<String> {
    args.into_iter().skip(1).find(|a| !a.starts_with('-') && Path::new(a).is_file())
}

#[tauri::command]
fn launch_path(launch: State<'_, Launch>) -> Option<String> {
    launch.0.lock().unwrap().take()
}

/// Brings the window to the front (a second launch of the app, with a song to play).
fn focus<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

/// This computer's name (what the other devices of the user see it as).
#[tauri::command]
fn device_name() -> String {
    std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_default()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            if let Some(path) = file_argument(argv) {
                let _ = app.emit("open-file", path);
            }
            focus(app);
        }))
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_http::init())
        .manage(library::Library::default())
        .manage(engine::Engine::default())
        .manage(cloud::Cloud::default())
        .manage(Launch(std::sync::Mutex::new(file_argument(std::env::args()))))
        .register_asynchronous_uri_scheme_protocol("media", library::serve)
        .invoke_handler(tauri::generate_handler![
            secret_get, secret_set, secret_delete, launch_path, device_name,
            library::library_get, library::library_scan, library::library_add_root, library::library_remove_root,
            library::library_open_file, library::library_reveal,
            engine::motor_status, engine::motor_latest, engine::motor_install, engine::motor_update_ytdlp, engine::motor_set_music_dir,
            engine::motor_start, engine::motor_stop, engine::motor_open_music_dir, engine::music_list, engine::music_remove,
            cloud::cloud_set, cloud::cloud_list, cloud::cloud_remove
        ])
        .build(tauri::generate_context!())
        .expect("error while running El Reproductor")
        .run(|app, event| {
            // the download engine ends with the app (it would anyway: it watches the app's process)
            if let tauri::RunEvent::Exit = event {
                engine::stop(&app.state::<engine::Engine>());
            }
        });
}
