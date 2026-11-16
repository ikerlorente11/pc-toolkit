//! Whether Windows Firewall lets the phones in. Windows asks the first time El Puntero listens, but only
//! allows it on the kind of network ticked (private, by default): on a network marked "public", after
//! closing that question, or when Windows never asked, the phone gets no answer at all and nothing says
//! why. The window warns about it and can add the rule (Windows asks for an administrator).

use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// One kind of network this PC is on right now and what the firewall does with El Puntero there.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct Profile {
    /// Domain, Private or Public
    pub profile: String,
    pub firewall: bool,
    pub allow: bool,
    pub block: bool,
}

/// Run with PUNTERO_EXE set: one Profile per kind of network the PC is connected to. Reading the rules
/// needs no administrator. A rule only counts if it is for this program (as Windows makes them).
const CHECK: &str = r#"
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$exe = $env:PUNTERO_EXE
$bits = @{ Domain = 1; Private = 2; Public = 4 }
$nets = @(Get-NetConnectionProfile | ForEach-Object { if ("$($_.NetworkCategory)" -eq 'DomainAuthenticated') { 'Domain' } else { "$($_.NetworkCategory)" } } | Select-Object -Unique)
$fw = @{}; Get-NetFirewallProfile -PolicyStore ActiveStore | ForEach-Object { $fw["$($_.Name)"] = "$($_.Enabled)" -ne 'False' }
$rules = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore | Where-Object { $_.Program -and [Environment]::ExpandEnvironmentVariables($_.Program) -ieq $exe } | Get-NetFirewallRule | Where-Object { "$($_.Enabled)" -eq 'True' -and "$($_.Direction)" -eq 'Inbound' })
$out = foreach ($n in $nets) {
  $bit = $bits[$n]; if (-not $bit) { continue }
  $on = { param($r) $p = [int]$r.Profile; $p -eq 0 -or ($p -band $bit) }
  [pscustomobject]@{
    profile = $n
    firewall = [bool]$fw[$n]
    allow = [bool]@($rules | Where-Object { "$($_.Action)" -eq 'Allow' -and (& $on $_) }).Count
    block = [bool]@($rules | Where-Object { "$($_.Action)" -eq 'Block' -and (& $on $_) }).Count
  }
}
ConvertTo-Json -Compress -InputObject @($out)
"#;

/// Run as administrator: takes away the rules that block El Puntero (Windows makes them when its
/// question is closed without allowing) and allows it on private and domain networks and on the ones the
/// PC is on now. `__EXE__` and `__PROFILES__` are filled in.
const ALLOW: &str = r#"
$ErrorActionPreference = 'Stop'
$exe = '__EXE__'
Get-NetFirewallApplicationFilter -PolicyStore PersistentStore | Where-Object { $_.Program -and [Environment]::ExpandEnvironmentVariables($_.Program) -ieq $exe } | Get-NetFirewallRule | Where-Object { "$($_.Direction)" -eq 'Inbound' -and "$($_.Action)" -eq 'Block' } | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName 'El Puntero' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'El Puntero' -Description 'Deja que los móviles emparejados controlen este PC (lo añade El Puntero)' -Direction Inbound -Action Allow -Program $exe -Protocol TCP -Profile __PROFILES__ | Out-Null
"#;

/// The last check, so the window (it asks every 2 s) does not start PowerShell each time.
static LAST: Mutex<Option<(Instant, Vec<Profile>)>> = Mutex::new(None);
static CHECKING: Mutex<bool> = Mutex::new(false);
const FRESH_FOR: Duration = Duration::from_secs(30);

fn exe() -> Option<String> {
    std::env::current_exe().ok().map(|p| p.to_string_lossy().into_owned())
}

fn check_now() -> Option<Vec<Profile>> {
    let exe = exe()?;
    let out = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &encode_command(CHECK)])
        .env("PUNTERO_EXE", exe)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    serde_json::from_slice(String::from_utf8_lossy(&out.stdout).trim().as_bytes()).ok()
}

/// What to tell in the window, from the last check (one is started in the background if it is old).
pub fn warning() -> Option<String> {
    let last = LAST.lock().unwrap().clone();
    let stale = last.as_ref().map(|(at, _)| at.elapsed() > FRESH_FOR).unwrap_or(true);
    if stale { refresh(); }
    last.and_then(|(_, profiles)| describe(&profiles))
}

/// Checks again in the background (after allowing it, or when the last check is old).
pub fn refresh() {
    {
        let mut checking = CHECKING.lock().unwrap();
        if *checking { return; }
        *checking = true;
    }
    std::thread::spawn(|| {
        if let Some(profiles) = check_now() { *LAST.lock().unwrap() = Some((Instant::now(), profiles)); }
        *CHECKING.lock().unwrap() = false;
    });
}

fn network_name(profile: &str) -> &'static str {
    match profile {
        "Public" => "pública",
        "Private" => "privada",
        _ => "de dominio",
    }
}

/// The networks where the firewall would stop the phones, if any.
pub fn describe(profiles: &[Profile]) -> Option<String> {
    let shut: Vec<&str> = profiles
        .iter()
        .filter(|p| p.firewall && (p.block || !p.allow))
        .map(|p| network_name(&p.profile))
        .collect();
    if shut.is_empty() { return None; }
    let kinds = shut.join(" y ");
    Some(format!("El firewall de Windows no deja que el móvil se conecte en esta red ({kinds})."))
}

/// Allows El Puntero in the firewall. Windows asks for an administrator; Err if it was not allowed.
pub fn allow() -> Result<(), String> {
    let exe = exe().ok_or("No se sabe dónde está El Puntero")?;
    let mut profiles = vec!["Domain".to_string(), "Private".to_string()];
    if let Some((_, now)) = LAST.lock().unwrap().as_ref() {
        for p in now { if !profiles.contains(&p.profile) { profiles.push(p.profile.clone()) } }
    }
    let script = ALLOW.replace("__EXE__", &exe.replace('\'', "''")).replace("__PROFILES__", &profiles.join(","));
    let encoded = encode_command(&script);
    // the elevated PowerShell is started by an ordinary one: Start-Process -Verb RunAs is what shows the
    // administrator question, and -Wait gives back how it ended
    let launcher = format!(
        "try {{ $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand','{encoded}'; exit $p.ExitCode }} catch {{ exit 1223 }}"
    );
    let status = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &launcher])
        .creation_flags(CREATE_NO_WINDOW)
        .status()
        .map_err(|e| e.to_string())?;
    *LAST.lock().unwrap() = None;
    refresh();
    match status.code() {
        Some(0) => Ok(()),
        Some(1223) => Err("No se ha dado permiso de administrador.".into()),
        _ => Err("Windows no ha dejado cambiar el firewall.".into()),
    }
}

/// PowerShell's -EncodedCommand: base64 of the script in UTF-16LE (no quoting to get wrong).
fn encode_command(script: &str) -> String {
    use base64::{engine::general_purpose::STANDARD as B64, Engine};
    let bytes: Vec<u8> = script.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    B64.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(name: &str, firewall: bool, allow: bool, block: bool) -> Profile {
        Profile { profile: name.into(), firewall, allow, block }
    }

    #[test]
    fn warns_only_where_it_is_shut() {
        assert_eq!(describe(&[profile("Private", true, true, false)]), None);
        assert_eq!(describe(&[profile("Public", false, false, false)]), None);
        let both = describe(&[profile("Private", true, true, false), profile("Public", true, false, false), profile("Domain", true, true, true)]);
        assert_eq!(both.as_deref(), Some("El firewall de Windows no deja que el móvil se conecte en esta red (pública y de dominio)."));
    }

    #[test]
    fn reads_the_check() {
        let json = r#"[{"profile":"Private","firewall":true,"allow":false,"block":false}]"#;
        let profiles: Vec<Profile> = serde_json::from_str(json).unwrap();
        assert_eq!(profiles, vec![profile("Private", true, false, false)]);
    }

    #[test]
    fn encodes_for_powershell() {
        assert_eq!(encode_command("ls"), "bABzAA==");
    }
}
