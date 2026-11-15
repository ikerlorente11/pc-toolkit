//! What the phone and the PC say to each other (the whole protocol is described in PROTOCOL.md of the
//! puntero repo). Every message is a JSON object with its kind in "t".

use serde::{Deserialize, Serialize};

pub const VERSION: u32 = 1;

/// The phone's first message, in the clear: who it is, with a box only the right key opens (it holds
/// the PC's challenge, so an old session cannot be replayed).
#[derive(Deserialize, Debug)]
#[serde(tag = "t", rename_all = "lowercase")]
pub enum Hello {
    /// A paired phone: its box is sealed with the key it got when pairing.
    Hello { dev: String, #[serde(rename = "box")] sealed: String },
    /// A new phone: its box (sealed with the QR's key or the 6-digit code) carries its own new key.
    Pair { dev: String, via: PairVia, #[serde(rename = "box")] sealed: String },
}

#[derive(Deserialize, Debug, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum PairVia { Qr, Code }

/// Inside the hello box.
#[derive(Deserialize, Debug)]
pub struct HelloBox {
    pub c: String,
    #[serde(default)]
    pub name: String,
    /// Only when pairing: the phone's key for every later session (base64, 32 bytes).
    #[serde(default)]
    pub key: Option<String>,
}

#[derive(Deserialize, Debug, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Button { Left, Right, Middle, X1, X2 }

#[derive(Deserialize, Debug, PartialEq, Clone, Copy, Default)]
#[serde(rename_all = "lowercase")]
pub enum Press {
    #[default]
    Click,
    Down,
    Up,
    Dbl,
}

#[derive(Deserialize, Debug, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Power { Lock, Sleep, Shutdown, Restart, Logoff, Screenoff }

#[derive(Deserialize, Debug, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum WindowAction { Focus, Close, Minimize, Maximize }

/// What the phone asks for once connected.
#[derive(Deserialize, Debug, PartialEq)]
#[serde(tag = "t", rename_all = "lowercase")]
pub enum Command {
    /// Move the pointer by this many pixels (fractions add up).
    #[serde(rename = "m")]
    Move { x: f64, y: f64 },
    Btn { b: Button, #[serde(default)] a: Press },
    /// Wheel units: 120 is one notch; fractions add up, so scrolling is smooth.
    Scroll { #[serde(default)] x: f64, #[serde(default)] y: f64 },
    /// Ctrl + wheel, in notches (positive zooms in).
    Zoom { d: f64 },
    Text { s: String },
    /// A key by name (keys.rs) with modifiers held around it.
    Key { k: String, #[serde(default)] mods: Vec<String>, #[serde(default)] a: Press },
    /// Volume 0..1 and/or mute; with neither, only asks for the current state.
    Vol { #[serde(default)] v: Option<f64>, #[serde(default)] mute: Option<bool> },
    Url { u: String },
    Apps,
    Launch { id: String },
    Windows,
    Win { id: i64, a: WindowAction },
    Power { a: Power },
    /// Puts this text in the PC's clipboard.
    Clip { s: String },
    /// Asks for the PC's clipboard.
    Clipget,
    Ping { n: u64 },
}

#[derive(Serialize, Debug, Clone)]
pub struct AppEntry { pub id: String, pub name: String }

#[derive(Serialize, Debug, Clone)]
pub struct WindowEntry { pub id: i64, pub title: String, pub exe: String, pub active: bool }

/// What the PC says.
#[derive(Serialize, Debug)]
#[serde(tag = "t", rename_all = "lowercase")]
pub enum Event {
    Welcome { name: String, id: String, version: String, v: u32, #[serde(skip_serializing_if = "Option::is_none")] paired: Option<bool> },
    Vol { v: f64, mute: bool },
    Apps { items: Vec<AppEntry> },
    Windows { items: Vec<WindowEntry> },
    Clip { s: String },
    Pong { n: u64 },
    Error { msg: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(json: &str) -> Command {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn parses_commands() {
        assert_eq!(cmd(r#"{"t":"m","x":1.5,"y":-2}"#), Command::Move { x: 1.5, y: -2.0 });
        assert_eq!(cmd(r#"{"t":"btn","b":"right"}"#), Command::Btn { b: Button::Right, a: Press::Click });
        assert_eq!(cmd(r#"{"t":"btn","b":"left","a":"down"}"#), Command::Btn { b: Button::Left, a: Press::Down });
        assert_eq!(cmd(r#"{"t":"scroll","y":-60}"#), Command::Scroll { x: 0.0, y: -60.0 });
        assert_eq!(
            cmd(r#"{"t":"key","k":"t","mods":["ctrl","shift"]}"#),
            Command::Key { k: "t".into(), mods: vec!["ctrl".into(), "shift".into()], a: Press::Click }
        );
        assert_eq!(cmd(r#"{"t":"vol"}"#), Command::Vol { v: None, mute: None });
        assert_eq!(cmd(r#"{"t":"win","id":42,"a":"close"}"#), Command::Win { id: 42, a: WindowAction::Close });
        assert_eq!(cmd(r#"{"t":"power","a":"screenoff"}"#), Command::Power { a: Power::Screenoff });
        assert_eq!(cmd(r#"{"t":"clipget"}"#), Command::Clipget);
    }

    #[test]
    fn rejects_unknown() {
        assert!(serde_json::from_str::<Command>(r#"{"t":"format-c"}"#).is_err());
        assert!(serde_json::from_str::<Command>(r#"{"t":"btn","b":"nose"}"#).is_err());
    }

    #[test]
    fn writes_events() {
        let json = serde_json::to_string(&Event::Vol { v: 0.5, mute: false }).unwrap();
        assert_eq!(json, r#"{"t":"vol","v":0.5,"mute":false}"#);
        let json = serde_json::to_string(&Event::Welcome { name: "PC".into(), id: "x".into(), version: "0.1.0".into(), v: 1, paired: None }).unwrap();
        assert_eq!(json, r#"{"t":"welcome","name":"PC","id":"x","version":"0.1.0","v":1}"#);
    }

    #[test]
    fn parses_hellos() {
        let h: Hello = serde_json::from_str(r#"{"t":"pair","dev":"d1","via":"qr","box":"AAAA"}"#).unwrap();
        assert!(matches!(h, Hello::Pair { via: PairVia::Qr, .. }));
        let h: Hello = serde_json::from_str(r#"{"t":"hello","dev":"d1","box":"AAAA"}"#).unwrap();
        assert!(matches!(h, Hello::Hello { .. }));
    }
}
