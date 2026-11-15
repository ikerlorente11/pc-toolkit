//! El Puntero for Windows: lets a phone (the El Puntero app) move this PC's pointer, click, scroll,
//! type, control media and volume, open apps and web pages, and more. It lives in the tray; the window
//! shows the QR a new phone scans to pair, and the phones paired.
//!
//! server.rs serves the phones, input.rs moves the pointer and presses keys, system.rs does the rest
//! (volume, windows, apps, power), state.rs remembers the paired phones, crypto.rs seals every message.

mod crypto;
mod input;
mod keys;
mod protocol;
mod server;
mod state;
mod system;

use serde::Serialize;
use state::State;
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

#[derive(Serialize)]
struct DeviceView {
    id: String,
    name: String,
    added: u64,
    last_seen: u64,
    connected: bool,
}

#[derive(Serialize)]
struct Status {
    version: &'static str,
    name: String,
    computer: String,
    port: u16,
    listening: bool,
    error: Option<String>,
    addresses: Vec<String>,
    code: String,
    qr: String,
    link: String,
    devices: Vec<DeviceView>,
    autostart: bool,
}

/// This PC's addresses on the local network, the most likely ones first (real network cards before
/// the virtual ones of WSL, Hyper-V, VirtualBox...).
fn addresses() -> Vec<String> {
    let mut found: Vec<(u8, String)> = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|iface| {
            let std::net::IpAddr::V4(ip) = iface.ip() else { return None };
            if ip.is_loopback() || ip.is_link_local() || ip.is_unspecified() { return None; }
            let name = iface.name.to_lowercase();
            let virtual_card = ["vethernet", "virtualbox", "vmware", "wsl", "hyper-v", "docker", "loopback", "vpn"]
                .iter()
                .any(|v| name.contains(v));
            let rank = if virtual_card { 3 } else if ip.is_private() { 0 } else if name.contains("tailscale") { 2 } else { 1 };
            Some((rank, ip.to_string()))
        })
        .collect();
    found.sort();
    found.dedup_by(|a, b| a.1 == b.1);
    found.into_iter().map(|(_, ip)| ip).collect()
}

fn url_encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// What the QR says: everything a phone needs to find and pair with this PC.
fn pair_link(state: &State, port: u16, addresses: &[String], secret: &crypto::SecretKey) -> String {
    let id = state.config.lock().unwrap().pc_id.clone();
    format!(
        "puntero://pair?v={}&id={}&n={}&p={}&h={}&k={}",
        protocol::VERSION,
        id,
        url_encode(&state.pc_name()),
        port,
        addresses.join(","),
        hex::encode(secret)
    )
}

fn qr_svg(text: &str) -> String {
    use qrcode::render::svg;
    qrcode::QrCode::with_error_correction_level(text.as_bytes(), qrcode::EcLevel::L)
        .map(|code| {
            code.render::<svg::Color>()
                .min_dimensions(220, 220)
                .quiet_zone(true)
                .dark_color(svg::Color("#111111"))
                .light_color(svg::Color("#ffffff"))
                .build()
        })
        .unwrap_or_default()
}

#[tauri::command]
fn status(app: AppHandle, state: tauri::State<'_, Arc<State>>) -> Status {
    let (code, secret) = state.pairing_shown();
    let server = state.server.lock().unwrap().clone();
    let config = state.config.lock().unwrap().clone();
    let addresses = addresses();
    let link = pair_link(&state, config.port, &addresses, &secret);
    let connected: Vec<String> = state.sessions.lock().unwrap().iter().map(|s| s.device.clone()).collect();
    let mut devices: Vec<DeviceView> = config
        .devices
        .iter()
        .map(|d| DeviceView {
            id: d.id.clone(),
            name: d.name.clone(),
            added: d.added,
            last_seen: d.last_seen,
            connected: connected.contains(&d.id),
        })
        .collect();
    devices.sort_by(|a, b| b.connected.cmp(&a.connected).then(b.last_seen.cmp(&a.last_seen)));
    Status {
        version: env!("CARGO_PKG_VERSION"),
        name: state.pc_name(),
        computer: std::env::var("COMPUTERNAME").unwrap_or_default(),
        port: config.port,
        listening: server.is_ok(),
        error: server.err(),
        qr: qr_svg(&link),
        link,
        addresses,
        code,
        devices,
        autostart: app.autolaunch().is_enabled().unwrap_or(false),
    }
}

#[tauri::command]
fn remove_device(id: String, state: tauri::State<'_, Arc<State>>) {
    state.remove_device(&id);
}

#[tauri::command]
fn set_name(name: String, state: tauri::State<'_, Arc<State>>) {
    state.config.lock().unwrap().name = name.trim().chars().take(40).collect();
    state.save();
}

#[tauri::command]
fn set_autostart(on: bool, app: AppHandle) -> Result<(), String> {
    let launcher = app.autolaunch();
    if on { launcher.enable() } else { launcher.disable() }.map_err(|e| e.to_string())
}

fn show(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let hidden = std::env::args().any(|a| a == "--hidden");
    tauri::Builder::default()
        // a second launch (the Start menu, PC Toolkit) shows the window of the one already running;
        // the one at sign-in (--hidden) only makes sure it runs
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            if !argv.iter().any(|a| a == "--hidden") { show(app); }
        }))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, Some(vec!["--hidden"])))
        .invoke_handler(tauri::generate_handler![status, remove_device, set_name, set_autostart])
        .setup(move |app| {
            let dir = app.path().app_config_dir().expect("the app's config folder");
            let state = Arc::new(State::load(dir.join("puntero.json")));
            app.manage(state.clone());

            let first_run = !state.config.lock().unwrap().autostart_set;
            if first_run {
                let _ = app.autolaunch().enable();
                state.config.lock().unwrap().autostart_set = true;
                state.save();
            }

            // development only: PUNTERO_DEV_LINK=<file> keeps pairing open and writes the QR's link
            // there, for the phone app's end-to-end tests (tests/server.test.ts in the puntero repo)
            #[cfg(debug_assertions)]
            if let Ok(file) = std::env::var("PUNTERO_DEV_LINK") {
                let state = state.clone();
                std::thread::spawn(move || loop {
                    let (code, secret) = state.pairing_shown();
                    let port = state.config.lock().unwrap().port;
                    let _ = std::fs::write(&file, pair_link(&state, port, &["127.0.0.1".to_string()], &secret));
                    let _ = std::fs::write(format!("{file}.code"), code);
                    std::thread::sleep(std::time::Duration::from_secs(5));
                });
            }

            tauri::async_runtime::spawn(server::run(state));

            let open = MenuItem::with_id(app, "open", "Abrir El Puntero", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Salir", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &quit])?;
            TrayIconBuilder::with_id("tray")
                .icon(app.default_window_icon().cloned().expect("the app's icon"))
                .tooltip("El Puntero")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => show(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                        show(tray.app_handle());
                    }
                })
                .build(app)?;

            if !hidden { show(app.handle()); }
            Ok(())
        })
        .on_window_event(|window, event| {
            // closing the window leaves El Puntero in the tray, still serving the phones
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running El Puntero");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_names() {
        assert_eq!(url_encode("PC de Iker"), "PC%20de%20Iker");
        assert_eq!(url_encode("Año"), "A%C3%B1o");
    }

    #[test]
    fn draws_the_qr() {
        let svg = qr_svg("puntero://pair?v=1&id=abc&n=PC&p=47810&h=192.168.1.10,10.0.0.2&k=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
        assert!(svg.starts_with("<?xml") || svg.starts_with("<svg"));
    }
}
