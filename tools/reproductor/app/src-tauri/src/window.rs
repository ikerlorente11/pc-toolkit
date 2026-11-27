//! The window beyond the page: what plays, shown and controlled from outside it.
//!
//! - Closing it can leave the app playing in the system tray (Ajustes › «Seguir sonando al cerrar»): the window hides,
//!   and the tray's icon opens it again, pauses, skips or quits for good.
//! - Its preview in the taskbar has the buttons of a music player (previous, play/pause, next), as Spotify's
//!   (`ITaskbarList3::ThumbBarAddButtons`; the window is subclassed to hear their clicks). They are put again when the
//!   Explorer starts again (`TaskbarButtonCreated`), and when the window comes back from the tray.
//!
//! The page says what plays (`media_state`); the buttons and the tray's menu tell it what to do with the `media` event
//! (`toggle`, `next`, `prev`), which it does as its own buttons would (also on another device, when it controls one).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, Runtime, Window, WindowEvent, Wry};

const TRAY: &str = "main";

/// What plays (for the tray's tooltip and menu, and the taskbar's buttons), and whether closing leaves it in the tray.
#[derive(Default)]
pub struct Media {
    background: AtomicBool,
    song: Mutex<Song>,
    /// the tray menu's play/pause entry, to say which it does
    toggle: Mutex<Option<MenuItem<Wry>>>,
}

#[derive(Default, Clone)]
struct Song {
    title: String,
    artist: String,
    playing: bool,
    loaded: bool,
}

impl Song {
    fn tooltip(&self) -> String {
        if self.title.is_empty() {
            return "El Reproductor".into();
        }
        let text = if self.artist.is_empty() { self.title.clone() } else { format!("{} · {}", self.title, self.artist) };
        // Windows cuts the tray's tooltip at 127 characters
        let text: String = text.chars().take(120).collect();
        text
    }
}

/// Brings the window back (from the tray, from minimized, from behind others).
pub fn show<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

/// Closing the window: with «Seguir sonando al cerrar», it hides in the tray (the music goes on).
pub fn on_event(window: &Window, event: &WindowEvent) {
    if let WindowEvent::CloseRequested { api, .. } = event {
        if window.label() == "main" && window.app_handle().state::<Media>().background.load(Ordering::SeqCst) {
            api.prevent_close();
            let _ = window.hide();
        }
    }
}

/// «Seguir sonando al cerrar» (Ajustes), as the page keeps it: on, the tray's icon is there.
#[tauri::command]
pub fn set_background(app: AppHandle, on: bool) -> Result<(), String> {
    let media = app.state::<Media>();
    media.background.store(on, Ordering::SeqCst);
    if on {
        if app.tray_by_id(TRAY).is_none() {
            make_tray(&app).map_err(|e| e.to_string())?;
        }
    } else {
        *media.toggle.lock().unwrap() = None;
        app.remove_tray_by_id(TRAY);
        // closed meanwhile (hidden): it comes back, or it could only be reached by opening the app again
        if let Some(window) = app.get_webview_window("main") {
            if !window.is_visible().unwrap_or(true) {
                show(&app);
            }
        }
    }
    Ok(())
}

/// What plays now: its title and artist, and whether it plays (`loaded`: there is a song at all).
#[tauri::command]
pub fn media_state(app: AppHandle, title: String, artist: String, playing: bool, loaded: bool) {
    let media = app.state::<Media>();
    let song = Song { title, artist, playing, loaded };
    *media.song.lock().unwrap() = song.clone();
    if let Some(tray) = app.tray_by_id(TRAY) {
        let _ = tray.set_tooltip(Some(song.tooltip()));
    }
    if let Some(item) = media.toggle.lock().unwrap().as_ref() {
        let _ = item.set_text(if playing { "Pausar" } else { "Reproducir" });
        let _ = item.set_enabled(loaded);
    }
    #[cfg(windows)]
    {
        thumb::PLAYING.store(playing, Ordering::SeqCst);
        thumb::LOADED.store(loaded, Ordering::SeqCst);
        let _ = app.run_on_main_thread(thumb::apply);
    }
}

fn make_tray(app: &AppHandle) -> tauri::Result<()> {
    let song = app.state::<Media>().song.lock().unwrap().clone();
    let open = MenuItem::with_id(app, "open", "Abrir El Reproductor", true, None::<&str>)?;
    let toggle = MenuItem::with_id(app, "toggle", if song.playing { "Pausar" } else { "Reproducir" }, song.loaded, None::<&str>)?;
    let next = MenuItem::with_id(app, "next", "Siguiente", true, None::<&str>)?;
    let prev = MenuItem::with_id(app, "prev", "Anterior", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Salir", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &PredefinedMenuItem::separator(app)?, &toggle, &next, &prev,
                                       &PredefinedMenuItem::separator(app)?, &quit])?;
    *app.state::<Media>().toggle.lock().unwrap() = Some(toggle);
    let mut tray = TrayIconBuilder::with_id(TRAY)
        .tooltip(song.tooltip())
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show(app),
            "quit" => app.exit(0),
            action @ ("toggle" | "next" | "prev") => { let _ = app.emit("media", action); }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                show(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(())
}

/// Puts the taskbar's buttons on the main window (Windows; on the main thread, once the window exists).
pub fn install(app: &AppHandle) {
    #[cfg(windows)]
    if let Some(window) = app.get_webview_window("main") {
        if let Ok(hwnd) = window.hwnd() {
            thumb::install(app.clone(), hwnd);
        }
    }
    #[cfg(not(windows))]
    let _ = app;
}

#[cfg(windows)]
mod thumb {
    use std::cell::RefCell;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::OnceLock;

    use tauri::{AppHandle, Emitter};
    use windows::core::w;
    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
    use windows::Win32::Graphics::Gdi::{CreateBitmap, DeleteObject};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED};
    use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
    use windows::Win32::UI::Shell::{
        DefSubclassProc, ITaskbarList3, SetWindowSubclass, TaskbarList, THBF_DISABLED, THBF_ENABLED, THB_FLAGS, THB_ICON,
        THB_TOOLTIP, THUMBBUTTON,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateIconIndirect, DestroyIcon, RegisterWindowMessageW, HICON, ICONINFO, SM_CXSMICON, WM_COMMAND, WM_DPICHANGED,
    };

    pub static PLAYING: AtomicBool = AtomicBool::new(false);
    pub static LOADED: AtomicBool = AtomicBool::new(false);
    static APP: OnceLock<AppHandle> = OnceLock::new();
    static CREATED: OnceLock<u32> = OnceLock::new();
    /// a click on a button of the preview (the high word of WM_COMMAND's wParam)
    const THBN_CLICKED: usize = 0x1800;
    const PREV: u32 = 1;
    const TOGGLE: u32 = 2;
    const NEXT: u32 = 3;

    /// The taskbar's list and the buttons' icons (COM: only on the main thread, where the window lives).
    struct Thumb {
        hwnd: HWND,
        list: ITaskbarList3,
        icons: Icons,
        added: bool,
    }
    struct Icons {
        prev: HICON,
        play: HICON,
        pause: HICON,
        next: HICON,
    }
    impl Drop for Icons {
        fn drop(&mut self) {
            for icon in [self.prev, self.play, self.pause, self.next] {
                unsafe { let _ = DestroyIcon(icon); }
            }
        }
    }
    thread_local! { static THUMB: RefCell<Option<Thumb>> = const { RefCell::new(None) }; }

    pub fn install(app: AppHandle, hwnd: HWND) {
        let _ = APP.set(app);
        CREATED.get_or_init(|| unsafe { RegisterWindowMessageW(w!("TaskbarButtonCreated")) });
        unsafe {
            let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
            let Ok(list) = CoCreateInstance::<_, ITaskbarList3>(&TaskbarList, None, CLSCTX_INPROC_SERVER) else { return };
            if list.HrInit().is_err() {
                return;
            }
            THUMB.with(|t| *t.borrow_mut() = Some(Thumb { hwnd, list, icons: icons(hwnd), added: false }));
            let _ = SetWindowSubclass(hwnd, Some(subclass), 1, 0);
        }
        // the taskbar's button may be there already (then the message came before the subclass)
        apply();
    }

    /// Puts the buttons (the first time) or updates them (what plays changed).
    pub fn apply() {
        THUMB.with(|t| {
            let Ok(mut t) = t.try_borrow_mut() else { return };
            let Some(t) = t.as_mut() else { return };
            let playing = PLAYING.load(Ordering::SeqCst);
            let flags = if LOADED.load(Ordering::SeqCst) { THBF_ENABLED } else { THBF_DISABLED };
            let buttons = [
                button(PREV, t.icons.prev, "Anterior", flags),
                button(TOGGLE, if playing { t.icons.pause } else { t.icons.play }, if playing { "Pausar" } else { "Reproducir" }, flags),
                button(NEXT, t.icons.next, "Siguiente", flags),
            ];
            unsafe {
                if !t.added {
                    // it fails while the taskbar has no button for the window yet: TaskbarButtonCreated comes then
                    t.added = t.list.ThumbBarAddButtons(t.hwnd, &buttons).is_ok();
                } else {
                    let _ = t.list.ThumbBarUpdateButtons(t.hwnd, &buttons);
                }
            }
        });
    }

    fn button(id: u32, icon: HICON, tip: &str, flags: windows::Win32::UI::Shell::THUMBBUTTONFLAGS) -> THUMBBUTTON {
        let mut b = THUMBBUTTON { dwMask: THB_ICON | THB_TOOLTIP | THB_FLAGS, iId: id, hIcon: icon, dwFlags: flags, ..Default::default() };
        for (i, c) in tip.encode_utf16().take(259).enumerate() {
            b.szTip[i] = c;
        }
        b
    }

    unsafe extern "system" fn subclass(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM, _id: usize, _data: usize) -> LRESULT {
        if Some(&msg) == CREATED.get() {
            // a new taskbar button (the Explorer started again, the window came back from the tray): put them again
            THUMB.with(|t| if let Ok(mut t) = t.try_borrow_mut() { if let Some(t) = t.as_mut() { t.added = false; } });
            apply();
        } else if msg == WM_COMMAND && (wp.0 >> 16) & 0xffff == THBN_CLICKED {
            let action = match (wp.0 & 0xffff) as u32 {
                PREV => "prev",
                TOGGLE => "toggle",
                NEXT => "next",
                _ => "",
            };
            if let (false, Some(app)) = (action.is_empty(), APP.get()) {
                let _ = app.emit("media", action);
            }
            return LRESULT(0);
        } else if msg == WM_DPICHANGED {
            // another screen's scale: the icons at its size
            THUMB.with(|t| if let Ok(mut t) = t.try_borrow_mut() { if let Some(t) = t.as_mut() { t.icons = icons(hwnd); } });
            let result = DefSubclassProc(hwnd, msg, wp, lp);
            apply();
            return result;
        }
        DefSubclassProc(hwnd, msg, wp, lp)
    }

    // ---- the icons: white, drawn here at the size of the window's screen (no files to ship) ----
    type Shape = fn(f32, f32) -> bool;

    fn icons(hwnd: HWND) -> Icons {
        let size = unsafe { GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForWindow(hwnd).max(96)) }.max(16) as usize;
        Icons { prev: icon(size, prev), play: icon(size, play), pause: icon(size, pause), next: icon(size, |x, y| prev(1.0 - x, y)) }
    }

    /// inside the triangle a, b, c
    fn tri(p: (f32, f32), a: (f32, f32), b: (f32, f32), c: (f32, f32)) -> bool {
        let side = |u: (f32, f32), v: (f32, f32)| (v.0 - u.0) * (p.1 - u.1) - (v.1 - u.1) * (p.0 - u.0);
        let (d1, d2, d3) = (side(a, b), side(b, c), side(c, a));
        !((d1 < 0.0 || d2 < 0.0 || d3 < 0.0) && (d1 > 0.0 || d2 > 0.0 || d3 > 0.0))
    }
    fn rect(x: f32, y: f32, x0: f32, x1: f32, y0: f32, y1: f32) -> bool {
        x >= x0 && x <= x1 && y >= y0 && y <= y1
    }
    fn play(x: f32, y: f32) -> bool {
        tri((x, y), (0.27, 0.16), (0.27, 0.84), (0.84, 0.5))
    }
    fn pause(x: f32, y: f32) -> bool {
        rect(x, y, 0.24, 0.41, 0.18, 0.82) || rect(x, y, 0.59, 0.76, 0.18, 0.82)
    }
    fn prev(x: f32, y: f32) -> bool {
        rect(x, y, 0.18, 0.29, 0.2, 0.8) || tri((x, y), (0.82, 0.2), (0.82, 0.8), (0.3, 0.5))
    }

    /// A white icon of `size` pixels with `shape` (in 0..1 of it), smoothed by sampling each pixel 4×4 times.
    fn icon(size: usize, shape: Shape) -> HICON {
        const SAMPLES: usize = 4;
        let mut pixels = vec![0u8; size * size * 4];
        for py in 0..size {
            for px in 0..size {
                let mut hits = 0;
                for sy in 0..SAMPLES {
                    for sx in 0..SAMPLES {
                        let x = (px as f32 + (sx as f32 + 0.5) / SAMPLES as f32) / size as f32;
                        let y = (py as f32 + (sy as f32 + 0.5) / SAMPLES as f32) / size as f32;
                        if shape(x, y) {
                            hits += 1;
                        }
                    }
                }
                let alpha = (hits * 255 / (SAMPLES * SAMPLES)) as u8;
                let i = (py * size + px) * 4;
                // BGRA: white, as opaque as the shape covers the pixel
                pixels[i..i + 4].copy_from_slice(&[255, 255, 255, alpha]);
            }
        }
        unsafe {
            let color = CreateBitmap(size as i32, size as i32, 1, 32, Some(pixels.as_ptr().cast()));
            let mask_bits = vec![0u8; size.div_ceil(16) * 2 * size];
            let mask = CreateBitmap(size as i32, size as i32, 1, 1, Some(mask_bits.as_ptr().cast()));
            let info = ICONINFO { fIcon: true.into(), xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color };
            let icon = CreateIconIndirect(&info).unwrap_or_default();
            let _ = DeleteObject(color.into());
            let _ = DeleteObject(mask.into());
            icon
        }
    }
}
