//! Everything else the phone can do with the PC: volume, open windows, installed apps, web addresses,
//! clipboard and power. Windows only.

use crate::protocol::{AppEntry, Power, WindowAction, WindowEntry};
use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

// ---------------------------------------------------------------- volume (Core Audio)

pub mod volume {
    use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
    use windows::Win32::Media::Audio::{eMultimedia, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};

    fn endpoint() -> windows::core::Result<IAudioEndpointVolume> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
            devices.GetDefaultAudioEndpoint(eRender, eMultimedia)?.Activate(CLSCTX_ALL, None)
        }
    }

    /// The default output's volume (0..1) and whether it is muted.
    pub fn get() -> Result<(f64, bool), String> {
        let ep = endpoint().map_err(|e| e.to_string())?;
        unsafe {
            let level = ep.GetMasterVolumeLevelScalar().map_err(|e| e.to_string())?;
            let mute = ep.GetMute().map_err(|e| e.to_string())?.as_bool();
            Ok((level as f64, mute))
        }
    }

    pub fn set(level: Option<f64>, mute: Option<bool>) -> Result<(), String> {
        let ep = endpoint().map_err(|e| e.to_string())?;
        unsafe {
            if let Some(level) = level.filter(|l| l.is_finite()) {
                ep.SetMasterVolumeLevelScalar(level.clamp(0.0, 1.0) as f32, std::ptr::null()).map_err(|e| e.to_string())?;
            }
            if let Some(mute) = mute {
                ep.SetMute(mute, std::ptr::null()).map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------- open windows

pub mod windows_list {
    use super::*;
    use windows::core::{BOOL, PWSTR};
    use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, WPARAM};
    use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED};
    use windows::Win32::System::Threading::{
        GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, KEYBD_EVENT_FLAGS, VK_MENU,
    };
    use windows::Win32::UI::WindowsAndMessaging::*;

    unsafe fn exe_of(hwnd: HWND) -> (u32, String) {
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        let mut name = String::new();
        if let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            let mut buf = [0u16; 1024];
            let mut len = buf.len() as u32;
            if QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok() {
                let path = String::from_utf16_lossy(&buf[..len as usize]);
                name = path.rsplit('\\').next().unwrap_or("").to_string();
            }
            let _ = CloseHandle(process);
        }
        (pid, name)
    }

    /// A window the user would see in Alt+Tab: visible, titled, not owned, not a tool window, not
    /// cloaked (the hidden windows of Store apps and of other virtual desktops).
    unsafe fn is_app_window(hwnd: HWND) -> bool {
        if !IsWindowVisible(hwnd).as_bool() || GetWindowTextLengthW(hwnd) == 0 { return false; }
        if GetWindow(hwnd, GW_OWNER).map(|o| !o.is_invalid()).unwrap_or(false) { return false; }
        let ex = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
        if ex & WS_EX_TOOLWINDOW.0 != 0 { return false; }
        let mut cloaked = 0u32;
        let _ = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut u32 as *mut _, 4);
        cloaked == 0
    }

    unsafe extern "system" fn collect(hwnd: HWND, data: LPARAM) -> BOOL {
        let list = &mut *(data.0 as *mut Vec<HWND>);
        if is_app_window(hwnd) { list.push(hwnd); }
        true.into()
    }

    pub fn list() -> Vec<WindowEntry> {
        unsafe {
            let mut hwnds: Vec<HWND> = Vec::new();
            let _ = EnumWindows(Some(collect), LPARAM(&mut hwnds as *mut _ as isize));
            let active = GetForegroundWindow();
            let me = GetCurrentProcessId();
            hwnds
                .into_iter()
                .filter_map(|hwnd| {
                    let mut buf = vec![0u16; GetWindowTextLengthW(hwnd) as usize + 1];
                    let len = GetWindowTextW(hwnd, &mut buf);
                    let (pid, exe) = exe_of(hwnd);
                    if pid == me { return None; }
                    Some(WindowEntry {
                        id: hwnd.0 as i64,
                        title: String::from_utf16_lossy(&buf[..len as usize]),
                        exe,
                        active: hwnd == active,
                    })
                })
                .collect()
        }
    }

    pub fn act(id: i64, action: WindowAction) -> Result<(), String> {
        unsafe {
            let hwnd = HWND(id as *mut _);
            if !IsWindow(Some(hwnd)).as_bool() || !is_app_window(hwnd) { return Err("Esa ventana ya no está abierta".into()); }
            match action {
                WindowAction::Close => { let _ = PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0)); }
                WindowAction::Minimize => { let _ = ShowWindow(hwnd, SW_MINIMIZE); }
                WindowAction::Maximize => { let _ = ShowWindow(hwnd, SW_MAXIMIZE); focus(hwnd); }
                WindowAction::Focus => {
                    if IsIconic(hwnd).as_bool() { let _ = ShowWindow(hwnd, SW_RESTORE); }
                    focus(hwnd);
                }
            }
        }
        Ok(())
    }

    /// Windows only lets the process that got the last input bring a window to the front: a tap of Alt
    /// first makes this one that process.
    unsafe fn focus(hwnd: HWND) {
        let alt = |flags| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VK_MENU, wScan: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
        };
        SendInput(&[alt(KEYBD_EVENT_FLAGS(0)), alt(KEYEVENTF_KEYUP)], std::mem::size_of::<INPUT>() as i32);
        let _ = SetForegroundWindow(hwnd);
    }
}

// ---------------------------------------------------------------- installed apps (Start menu)

static APPS: Mutex<Option<(Instant, Vec<AppEntry>)>> = Mutex::new(None);

/// The apps of the Start menu, desktop and Store ones alike (PowerShell's Get-StartApps), cached for
/// a minute. Their id is an AppUserModelID, which `shell:AppsFolder` opens.
pub fn apps() -> Result<Vec<AppEntry>, String> {
    if let Some((at, list)) = APPS.lock().unwrap().as_ref() {
        if at.elapsed() < Duration::from_secs(60) { return Ok(list.clone()); }
    }
    let out = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command",
            "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-StartApps | Select-Object Name,AppID | ConvertTo-Json -Compress"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| e.to_string())?;
    let list = parse_start_apps(&String::from_utf8_lossy(&out.stdout));
    *APPS.lock().unwrap() = Some((Instant::now(), list.clone()));
    Ok(list)
}

pub fn parse_start_apps(json: &str) -> Vec<AppEntry> {
    let value: serde_json::Value = serde_json::from_str(json.trim()).unwrap_or(serde_json::Value::Null);
    let items = match value {
        serde_json::Value::Array(items) => items,
        single @ serde_json::Value::Object(_) => vec![single],
        _ => vec![],
    };
    let mut list: Vec<AppEntry> = items
        .iter()
        .filter_map(|v| {
            let name = v.get("Name")?.as_str()?.trim().to_string();
            let id = v.get("AppID")?.as_str()?.trim().to_string();
            // uninstallers, help files and web links of the Start menu are not apps
            let lower = name.to_lowercase();
            if name.is_empty() || id.is_empty() || lower.starts_with("uninstall") || lower.starts_with("desinstalar")
                || id.starts_with("http") || id.ends_with(".chm") || id.ends_with(".txt") || id.ends_with(".url") {
                return None;
            }
            Some(AppEntry { id, name })
        })
        .collect();
    list.sort_by_key(|a| a.name.to_lowercase());
    list.dedup_by(|a, b| a.id == b.id);
    list
}

pub fn launch(id: &str) -> Result<(), String> {
    // only ids from the list: nothing the phone sends ends up on a command line unchecked
    if !apps()?.iter().any(|a| a.id == id) { return Err("Esa app ya no está instalada".into()); }
    Command::new("explorer.exe")
        .arg(format!("shell:AppsFolder\\{id}"))
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------- web addresses

/// What the user typed, as an address the browser can open: http(s) only (a file:// or a program
/// would be another way to run things), "https://" added when missing, spaces made a web search.
pub fn web_address(input: &str) -> Option<String> {
    let input = input.trim();
    if input.is_empty() || input.len() > 4000 { return None; }
    let lower = input.to_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        return if input.contains(char::is_whitespace) { None } else { Some(input.to_string()) };
    }
    if lower.contains("://") || lower.starts_with("javascript:") || lower.starts_with("file:") { return None; }
    let looks_like_host = !input.contains(char::is_whitespace) && (input.contains('.') || lower.starts_with("localhost"));
    if looks_like_host {
        Some(format!("https://{input}"))
    } else {
        let query: String = input.bytes().map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            b' ' => "+".to_string(),
            _ => format!("%{b:02X}"),
        }).collect();
        Some(format!("https://www.google.com/search?q={query}"))
    }
}

pub fn open_url(input: &str) -> Result<(), String> {
    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
    let url = web_address(input).ok_or("Esa dirección no es una web")?;
    let result = unsafe { ShellExecuteW(None, &HSTRING::from("open"), &HSTRING::from(url.as_str()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL) };
    if result.0 as isize <= 32 { return Err("No se ha podido abrir el navegador".into()); }
    Ok(())
}

// ---------------------------------------------------------------- clipboard

pub fn clipboard_set(text: &str) -> Result<(), String> {
    arboard::Clipboard::new().and_then(|mut c| c.set_text(text.to_string())).map_err(|e| e.to_string())
}

pub fn clipboard_get() -> Result<String, String> {
    arboard::Clipboard::new().and_then(|mut c| c.get_text()).map_err(|_| "El portapapeles no tiene texto".to_string())
}

// ---------------------------------------------------------------- power

pub fn power(action: Power) -> Result<(), String> {
    use windows::Win32::Foundation::{LPARAM, WPARAM};
    use windows::Win32::System::Power::SetSuspendState;
    use windows::Win32::System::Shutdown::LockWorkStation;
    use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, HWND_BROADCAST, SC_MONITORPOWER, WM_SYSCOMMAND};
    let shutdown = |args: &[&str]| {
        Command::new("shutdown.exe").args(args).creation_flags(CREATE_NO_WINDOW).spawn().map(|_| ()).map_err(|e| e.to_string())
    };
    unsafe {
        match action {
            Power::Lock => LockWorkStation().map_err(|e| e.to_string()),
            Power::Sleep => {
                // asleep a moment later, so the phone gets its answer first
                std::thread::spawn(|| { std::thread::sleep(Duration::from_millis(400)); SetSuspendState(false, false, false); });
                Ok(())
            }
            Power::Shutdown => shutdown(&["/s", "/t", "0"]),
            Power::Restart => shutdown(&["/r", "/t", "0"]),
            Power::Logoff => shutdown(&["/l"]),
            Power::Screenoff => {
                // the next move of the pointer turns the screens back on
                let _ = PostMessageW(Some(HWND_BROADCAST), WM_SYSCOMMAND, WPARAM(SC_MONITORPOWER as usize), LPARAM(2));
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn web_addresses() {
        assert_eq!(web_address("youtube.com").as_deref(), Some("https://youtube.com"));
        assert_eq!(web_address(" https://a.b/c?d=1 ").as_deref(), Some("https://a.b/c?d=1"));
        assert_eq!(web_address("http://192.168.1.1").as_deref(), Some("http://192.168.1.1"));
        assert_eq!(web_address("localhost:8080").as_deref(), Some("https://localhost:8080"));
        assert_eq!(web_address("receta tortilla").as_deref(), Some("https://www.google.com/search?q=receta+tortilla"));
        assert_eq!(web_address("año").as_deref(), Some("https://www.google.com/search?q=a%C3%B1o"));
        assert_eq!(web_address("file:///C:/Windows/System32/cmd.exe"), None);
        assert_eq!(web_address("javascript:alert(1)"), None);
        assert_eq!(web_address("ms-settings://display"), None);
        assert_eq!(web_address(""), None);
    }

    #[test]
    fn start_apps() {
        let json = r#"[{"Name":"Spotify","AppID":"Spotify.exe"},{"Name":"Uninstall Foo","AppID":"x"},
            {"Name":"Calculadora","AppID":"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"},
            {"Name":"Web","AppID":"https://example.com"},{"Name":"Spotify","AppID":"Spotify.exe"}]"#;
        let list = parse_start_apps(json);
        let names: Vec<_> = list.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(names, vec!["Calculadora", "Spotify"]);
        assert_eq!(parse_start_apps(r#"{"Name":"Solo","AppID":"solo.exe"}"#).len(), 1);
        assert!(parse_start_apps("").is_empty());
    }
}
