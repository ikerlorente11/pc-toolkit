//! What the app remembers (this PC's id and name, the port, the paired phones and their keys, in
//! puntero.json of the app's config folder) and what it only keeps while running: the pairing code and
//! QR key, and the phones connected right now.

use crate::crypto::{self, SecretKey};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const DEFAULT_PORT: u16 = 47810;
/// Pairing is open while the window is on screen (it asks for the status every few seconds) and a
/// little after.
const PAIRING_OPEN_FOR: Duration = Duration::from_secs(20);
/// The code and QR key change this often, after a phone pairs, and after this many wrong tries.
const PAIRING_LIFETIME: Duration = Duration::from_secs(10 * 60);
const PAIRING_MAX_FAILURES: u32 = 5;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Device {
    pub id: String,
    pub name: String,
    /// base64 of the 32-byte key the phone made when pairing
    pub key: String,
    pub added: u64,
    #[serde(default)]
    pub last_seen: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Config {
    pub pc_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default)]
    pub devices: Vec<Device>,
    /// "Start with Windows" is switched on the first time the app runs; after that it is the user's.
    #[serde(default)]
    pub autostart_set: bool,
}

fn default_port() -> u16 { DEFAULT_PORT }

impl Default for Config {
    fn default() -> Self {
        Config { pc_id: hex::encode(crypto::random::<8>()), name: String::new(), port: DEFAULT_PORT, devices: vec![], autostart_set: false }
    }
}

pub struct Pairing {
    pub code: String,
    pub secret: SecretKey,
    created: Instant,
    failures: u32,
    open_until: Option<Instant>,
}

impl Pairing {
    fn new() -> Self {
        let n = u32::from_le_bytes(crypto::random::<4>()) % 1_000_000;
        Pairing { code: format!("{n:06}"), secret: crypto::random(), created: Instant::now(), failures: 0, open_until: None }
    }
}

#[derive(Serialize, Clone, Debug)]
pub struct Session {
    pub id: u64,
    pub device: String,
    pub name: String,
    pub addr: String,
}

pub struct State {
    path: PathBuf,
    pub config: Mutex<Config>,
    pub pairing: Mutex<Pairing>,
    pub sessions: Mutex<Vec<Session>>,
    next_session: Mutex<u64>,
    /// "Listening on ..." or why not (port in use...), for the window.
    pub server: Mutex<Result<u16, String>>,
    /// A device id sent here ends that phone's sessions (it was removed in the window).
    pub kick: tokio::sync::broadcast::Sender<String>,
}

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl State {
    pub fn load(path: PathBuf) -> Self {
        let config = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<Config>(&text).ok())
            .unwrap_or_default();
        let state = State {
            path,
            config: Mutex::new(config),
            pairing: Mutex::new(Pairing::new()),
            sessions: Mutex::new(vec![]),
            next_session: Mutex::new(1),
            server: Mutex::new(Err("Arrancando…".into())),
            kick: tokio::sync::broadcast::channel(8).0,
        };
        state.save();
        state
    }

    pub fn save(&self) {
        let config = self.config.lock().unwrap().clone();
        if let Some(dir) = self.path.parent() { let _ = std::fs::create_dir_all(dir); }
        if let Ok(text) = serde_json::to_string_pretty(&config) {
            let tmp = self.path.with_extension("json.tmp");
            if std::fs::write(&tmp, text).is_ok() { let _ = std::fs::rename(&tmp, &self.path); }
        }
    }

    /// The name phones show: the one set in the window, or the computer's.
    pub fn pc_name(&self) -> String {
        let name = self.config.lock().unwrap().name.clone();
        if !name.trim().is_empty() { return name; }
        std::env::var("COMPUTERNAME").unwrap_or_else(|_| "PC".into())
    }

    /// The current code and QR key (new ones when they are too old); the window asking keeps pairing open.
    pub fn pairing_shown(&self) -> (String, SecretKey) {
        let mut p = self.pairing.lock().unwrap();
        if p.created.elapsed() > PAIRING_LIFETIME { *p = Pairing::new(); }
        p.open_until = Some(Instant::now() + PAIRING_OPEN_FOR);
        (p.code.clone(), p.secret)
    }

    pub fn pairing_open(&self) -> bool {
        let p = self.pairing.lock().unwrap();
        p.open_until.map(|t| Instant::now() < t).unwrap_or(false) && p.created.elapsed() <= PAIRING_LIFETIME
    }

    /// The key a pairing request may be sealed with, if pairing is open.
    pub fn pairing_key(&self, via: crate::protocol::PairVia) -> Option<SecretKey> {
        if !self.pairing_open() { return None; }
        let p = self.pairing.lock().unwrap();
        Some(match via {
            crate::protocol::PairVia::Qr => p.secret,
            crate::protocol::PairVia::Code => crypto::code_key(&p.code),
        })
    }

    pub fn pairing_failed(&self) {
        let mut p = self.pairing.lock().unwrap();
        p.failures += 1;
        if p.failures >= PAIRING_MAX_FAILURES {
            let open_until = p.open_until;
            *p = Pairing::new();
            p.open_until = open_until;
        }
    }

    /// A phone paired: it is remembered (again, if it was already) and the code changes.
    pub fn add_device(&self, id: &str, name: &str, key: &SecretKey) {
        {
            let mut config = self.config.lock().unwrap();
            config.devices.retain(|d| d.id != id);
            config.devices.push(Device {
                id: id.to_string(),
                name: clean_name(name),
                key: B64.encode(key),
                added: now(),
                last_seen: now(),
            });
        }
        self.save();
        let mut p = self.pairing.lock().unwrap();
        let open_until = p.open_until;
        *p = Pairing::new();
        p.open_until = open_until;
    }

    pub fn device_key(&self, id: &str) -> Option<SecretKey> {
        let config = self.config.lock().unwrap();
        let device = config.devices.iter().find(|d| d.id == id)?;
        B64.decode(&device.key).ok()?.try_into().ok()
    }

    pub fn device_seen(&self, id: &str, name: &str) {
        let mut config = self.config.lock().unwrap();
        if let Some(d) = config.devices.iter_mut().find(|d| d.id == id) {
            d.last_seen = now();
            if !name.trim().is_empty() { d.name = clean_name(name); }
        }
    }

    pub fn remove_device(&self, id: &str) {
        self.config.lock().unwrap().devices.retain(|d| d.id != id);
        self.save();
        let _ = self.kick.send(id.to_string());
    }

    pub fn session_start(&self, device: &str, name: &str, addr: String) -> u64 {
        let mut next = self.next_session.lock().unwrap();
        let id = *next;
        *next += 1;
        self.sessions.lock().unwrap().push(Session { id, device: device.into(), name: clean_name(name), addr });
        id
    }

    pub fn session_end(&self, id: u64) {
        self.sessions.lock().unwrap().retain(|s| s.id != id);
        self.save();   // last_seen
    }
}

fn clean_name(name: &str) -> String {
    let name: String = name.chars().filter(|c| !c.is_control()).take(60).collect();
    if name.trim().is_empty() { "Móvil".into() } else { name.trim().to_string() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::PairVia;

    fn temp_state() -> State {
        let dir = std::env::temp_dir().join(format!("puntero-test-{}", hex::encode(crypto::random::<6>())));
        State::load(dir.join("puntero.json"))
    }

    #[test]
    fn pairing_only_while_shown() {
        let state = temp_state();
        assert!(state.pairing_key(PairVia::Qr).is_none());
        let (code, secret) = state.pairing_shown();
        assert_eq!(code.len(), 6);
        assert_eq!(state.pairing_key(PairVia::Qr), Some(secret));
        assert_eq!(state.pairing_key(PairVia::Code), Some(crypto::code_key(&code)));
    }

    #[test]
    fn code_changes_after_failures_and_pairing() {
        let state = temp_state();
        let (code, _) = state.pairing_shown();
        for _ in 0..PAIRING_MAX_FAILURES { state.pairing_failed(); }
        let (after_failures, _) = state.pairing_shown();
        let (_, secret) = state.pairing_shown();
        state.add_device("d1", "Mi\u{0}móvil", &[7u8; 32]);
        let (_, new_secret) = state.pairing_shown();
        assert_ne!(secret, new_secret);
        // (the 6 digits could repeat by chance; the QR key cannot)
        let _ = (code, after_failures);
        assert!(state.pairing_open());
    }

    #[test]
    fn remembers_devices() {
        let state = temp_state();
        state.add_device("d1", "Xiaomi", &[7u8; 32]);
        assert_eq!(state.device_key("d1"), Some([7u8; 32]));
        assert_eq!(state.device_key("d2"), None);
        let again = State::load(state.path.clone());
        assert_eq!(again.device_key("d1"), Some([7u8; 32]));
        assert_eq!(again.config.lock().unwrap().devices[0].name, "Xiaomi");
        again.remove_device("d1");
        assert_eq!(again.device_key("d1"), None);
        let _ = std::fs::remove_dir_all(state.path.parent().unwrap());
    }
}
