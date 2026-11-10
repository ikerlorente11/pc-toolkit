//! La Estantería for the desktop: a Tauri shell around the shared viewer. The Rust side keeps the
//! user's app token in the operating system's credential store and the items made available
//! offline (see offline.rs); everything else happens in the web view against the service of the
//! user's Archivador.

mod offline;

const SERVICE: &str = "La Estantería";

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
    keyring::Entry::new(SERVICE, &account)
        .and_then(|e| e.set_password(&secret))
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn secret_delete(account: String) -> Result<(), String> {
    match keyring::Entry::new(SERVICE, &account).and_then(|e| e.delete_credential()) {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_opener::init())
        .manage(offline::Jobs::default())
        .register_uri_scheme_protocol("offline", offline::serve)
        .invoke_handler(tauri::generate_handler![
            secret_get, secret_set, secret_delete,
            offline::offline_start, offline::offline_list, offline::offline_remove, offline::offline_where
        ])
        .run(tauri::generate_context!())
        .expect("error while running La Estantería");
}
