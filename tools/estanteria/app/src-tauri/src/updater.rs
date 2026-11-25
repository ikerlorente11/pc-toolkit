//! The app updates itself when PC Toolkit does not do it for it (installed by hand from the release's setup.exe):
//! it looks at the newest release of its own (tag `<TAG>v<version>` of the pc-toolkit repo), downloads its installer in
//! the background and runs it silently, for the current user — on asking («Reiniciar ahora», then the app opens
//! again) or when the app closes. With PC Toolkit's tool installed (its scheduled task exists), PC Toolkit updates it:
//! the app does nothing, so they never fight.
//!
//! The same file in La Estantería and El Reproductor; only the constants change.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Manager, Runtime, State};

const RELEASES: &str = "https://api.github.com/repos/ikerlorente11/pc-toolkit/releases?per_page=40";
/// the app's release tags: `<TAG>v<version>`
const TAG: &str = "estanteria-";
/// PC Toolkit's scheduled task for this app's tool (it exists while the tool is installed)
const TASK: &str = "PcToolkitEstanteria";

#[derive(Default)]
pub struct Updater {
    /// the installer downloaded and the version it brings
    ready: Mutex<Option<(PathBuf, String)>>,
}

#[derive(Serialize, Clone, Default)]
pub struct UpdateStatus {
    current: String,
    /// PC Toolkit updates this app: the app does not
    managed: bool,
    /// a newer version published, if any
    latest: Option<String>,
    /// downloaded and ready to install
    ready: Option<String>,
}

/// "0.10.2" > "0.9.9": numbers compared one by one.
fn newer(a: &str, b: &str) -> bool {
    let parts = |v: &str| v.split('.').map(|p| p.trim().parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    parts(a) > parts(b)
}

/// PC Toolkit manages the app when its tool's scheduled task exists.
fn managed() -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        return std::process::Command::new("schtasks")
            .args(["/Query", "/TN", TASK])
            .creation_flags(0x0800_0000)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
    }
    #[allow(unreachable_code)]
    false
}

/// The newest release of the app: its version and its installer's address.
fn latest() -> Result<Option<(String, String)>, String> {
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(30)).build();
    let releases: serde_json::Value = agent
        .get(RELEASES)
        .set("User-Agent", "pc-toolkit-app-updater")
        .set("Accept", "application/vnd.github+json")
        .call()
        .map_err(|e| e.to_string())?
        .into_json()
        .map_err(|e| e.to_string())?;
    for r in releases.as_array().into_iter().flatten() {
        let tag = r["tag_name"].as_str().unwrap_or_default();
        if r["draft"].as_bool() == Some(true) || r["prerelease"].as_bool() == Some(true) {
            continue;
        }
        let Some(version) = tag.strip_prefix(TAG).and_then(|t| t.strip_prefix('v')) else { continue };
        if let Some(a) = r["assets"].as_array().into_iter().flatten().find(|a| a["name"].as_str().is_some_and(|n| n.ends_with("setup.exe"))) {
            return Ok(Some((version.to_string(), a["browser_download_url"].as_str().unwrap_or_default().to_string())));
        }
    }
    Ok(None)
}

/// Looks for a newer version and, unless PC Toolkit takes care of it, downloads it (to install on asking or on closing).
#[tauri::command]
pub async fn update_check<R: Runtime>(app: AppHandle<R>) -> Result<UpdateStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let current = app.package_info().version.to_string();
        let mut status = UpdateStatus { current: current.clone(), managed: managed(), ..Default::default() };
        if status.managed {
            return Ok(status);
        }
        let updater = app.state::<Updater>();
        if let Some((_, v)) = updater.ready.lock().unwrap().as_ref() {
            status.ready = Some(v.clone());
            status.latest = Some(v.clone());
            return Ok(status);
        }
        let Some((version, url)) = latest()? else { return Ok(status) };
        if !newer(&version, &current) {
            return Ok(status);
        }
        status.latest = Some(version.clone());
        let file = std::env::temp_dir().join(url.rsplit('/').next().unwrap_or("setup.exe"));
        let res = ureq::AgentBuilder::new().timeout_read(Duration::from_secs(120)).build().get(&url)
            .set("User-Agent", "pc-toolkit-app-updater").call().map_err(|e| e.to_string())?;
        let part = file.with_extension("part");
        let mut out = std::fs::File::create(&part).map_err(|e| e.to_string())?;
        std::io::copy(&mut res.into_reader(), &mut out).map_err(|e| e.to_string())?;
        drop(out);
        std::fs::rename(&part, &file).map_err(|e| e.to_string())?;
        *updater.ready.lock().unwrap() = Some((file, version.clone()));
        status.ready = Some(version);
        Ok(status)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Runs the installer downloaded, silently, once this app has closed; `reopen`: the app opens again after.
fn launch_installer(setup: &PathBuf, reopen: bool) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let exe = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let then = if reopen { format!(" & start \"\" \"{exe}\"") } else { String::new() };
        let line = format!("timeout /t 2 /nobreak >nul & \"{}\" /S /currentuser{then}", setup.display());
        let _ = std::process::Command::new("cmd").raw_arg(format!("/C \"{line}\"")).creation_flags(0x0800_0000 | 0x0000_0008).spawn();
    }
}

/// «Reiniciar ahora»: closes the app, installs the new version and opens it again.
#[tauri::command]
pub fn update_install<R: Runtime>(app: AppHandle<R>, updater: State<'_, Updater>) -> Result<(), String> {
    let (setup, _) = updater.ready.lock().unwrap().take().ok_or("no hay ninguna versión nueva descargada")?;
    launch_installer(&setup, true);
    app.exit(0);
    Ok(())
}

/// On closing: a version downloaded and not installed yet installs now (the app is not opened again).
pub fn on_exit<R: Runtime>(app: &AppHandle<R>) {
    if let Some((setup, _)) = app.state::<Updater>().ready.lock().unwrap().take() {
        launch_installer(&setup, false);
    }
}

#[cfg(test)]
mod tests {
    use super::newer;

    #[test]
    fn versions() {
        assert!(newer("0.2.1", "0.2.0"));
        assert!(newer("0.10.0", "0.9.9"));
        assert!(!newer("0.2.0", "0.2.0"));
        assert!(!newer("0.1.9", "0.2.0"));
    }
}
