//! Key names the phone uses, as Windows virtual-key codes. "Extended" keys (arrows, Insert/Delete,
//! Home/End, Page Up/Down, the right-hand Ctrl/Alt, Windows, media keys...) need the extended flag so
//! programs that read scan codes (games, remote desktops) see the right key.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Vk {
    pub code: u16,
    pub extended: bool,
}

const fn k(code: u16) -> Vk { Vk { code, extended: false } }
const fn e(code: u16) -> Vk { Vk { code, extended: true } }

pub fn lookup(name: &str) -> Option<Vk> {
    let name = name.to_ascii_lowercase();
    let n = name.as_str();
    // letters and digits: their VK is their ASCII upper-case code
    if n.len() == 1 {
        let c = n.as_bytes()[0];
        if c.is_ascii_lowercase() { return Some(k(c.to_ascii_uppercase() as u16)); }
        if c.is_ascii_digit() { return Some(k(c as u16)); }
    }
    // F1..F24
    if let Some(num) = n.strip_prefix('f').and_then(|d| d.parse::<u16>().ok()) {
        if (1..=24).contains(&num) { return Some(k(0x70 + num - 1)); }
    }
    // numeric keypad digits: num0..num9
    if let Some(num) = n.strip_prefix("num").and_then(|d| d.parse::<u16>().ok()) {
        if num <= 9 { return Some(k(0x60 + num)); }
    }
    Some(match n {
        "backspace" => k(0x08),
        "tab" => k(0x09),
        "enter" => k(0x0D),
        "shift" => k(0x10),
        "ctrl" => k(0x11),
        "alt" => k(0x12),
        "pause" => k(0x13),
        "capslock" => k(0x14),
        "esc" | "escape" => k(0x1B),
        "space" => k(0x20),
        "pageup" => e(0x21),
        "pagedown" => e(0x22),
        "end" => e(0x23),
        "home" => e(0x24),
        "left" => e(0x25),
        "up" => e(0x26),
        "right" => e(0x27),
        "down" => e(0x28),
        "printscreen" => e(0x2C),
        "insert" => e(0x2D),
        "delete" => e(0x2E),
        "win" => e(0x5B),
        "menu" => e(0x5D),
        "multiply" => k(0x6A),
        "add" => k(0x6B),
        "subtract" => k(0x6D),
        "decimal" => k(0x6E),
        "divide" => e(0x6F),
        "numlock" => e(0x90),
        "scrolllock" => k(0x91),
        "rctrl" => e(0xA3),
        "ralt" | "altgr" => e(0xA5),
        "browserback" => e(0xA6),
        "browserforward" => e(0xA7),
        "browserrefresh" => e(0xA8),
        "browserstop" => e(0xA9),
        "browsersearch" => e(0xAA),
        "browserfavorites" => e(0xAB),
        "browserhome" => e(0xAC),
        "mute" => e(0xAD),
        "voldown" => e(0xAE),
        "volup" => e(0xAF),
        "next" => e(0xB0),
        "prev" => e(0xB1),
        "stop" => e(0xB2),
        "playpause" => e(0xB3),
        "mail" => e(0xB4),
        "media" => e(0xB5),
        // punctuation of a Spanish/US keyboard is better sent as text; these are the common ones
        "comma" => k(0xBC),
        "period" => k(0xBE),
        "minus" => k(0xBD),
        "plus" => k(0xBB),
        _ => return None,
    })
}

pub fn is_modifier(vk: Vk) -> bool {
    matches!(vk.code, 0x10 | 0x11 | 0x12 | 0x5B | 0xA3 | 0xA5)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_digits_and_functions() {
        assert_eq!(lookup("a"), Some(k(0x41)));
        assert_eq!(lookup("Z"), Some(k(0x5A)));
        assert_eq!(lookup("7"), Some(k(0x37)));
        assert_eq!(lookup("f1"), Some(k(0x70)));
        assert_eq!(lookup("F12"), Some(k(0x7B)));
        assert_eq!(lookup("f25"), None);
        assert_eq!(lookup("num5"), Some(k(0x65)));
    }

    #[test]
    fn named_keys() {
        assert_eq!(lookup("enter"), Some(k(0x0D)));
        assert_eq!(lookup("left"), Some(e(0x25)));
        assert_eq!(lookup("playpause"), Some(e(0xB3)));
        assert!(lookup("win").unwrap().extended);
        assert_eq!(lookup("nada"), None);
        assert!(is_modifier(lookup("ctrl").unwrap()));
        assert!(!is_modifier(lookup("a").unwrap()));
    }
}
