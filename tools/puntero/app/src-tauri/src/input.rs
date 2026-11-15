//! The phone's pointer, buttons, wheel and keys turned into input events. `Injector` keeps the
//! fractions of pixels and wheel units between messages and decides what to send; a `Sink` sends it
//! (`SendInputSink` on Windows, a list in the tests).
//!
//! The pointer moves to an absolute position (where it is now plus the phone's delta): relative moves
//! would go through Windows' own pointer acceleration on top of the phone's, which feels floaty.

use crate::keys::{self, Vk};
use crate::protocol::{Button, Press};

#[derive(Debug, Clone, PartialEq)]
pub enum Ev {
    /// Move to this point of the virtual desktop (or, with `relative`, by this much).
    Move { x: i32, y: i32, relative: bool },
    Button { b: Button, down: bool },
    Wheel { delta: i32, horizontal: bool },
    Key { vk: Vk, down: bool },
    /// One UTF-16 unit typed as itself (any language, emoji, accents...).
    Unicode { unit: u16, down: bool },
}

pub trait Sink {
    fn send(&mut self, events: &[Ev]);
    /// Where the pointer is, and the rectangle of the screen it is on (left, top, right, bottom,
    /// right/bottom exclusive). `None` on the secure desktop or in the tests that do not need it.
    fn cursor(&mut self) -> Option<((i32, i32), (i32, i32, i32, i32))>;
    /// The screen nearest to a point, to keep the pointer inside the monitors when they have gaps.
    fn screen_at(&mut self, x: i32, y: i32) -> (i32, i32, i32, i32);
}

#[derive(Default)]
pub struct Injector {
    rest_x: f64,
    rest_y: f64,
    wheel_x: f64,
    wheel_y: f64,
    zoom: f64,
}

impl Injector {
    pub fn move_by(&mut self, sink: &mut dyn Sink, dx: f64, dy: f64) {
        if !dx.is_finite() || !dy.is_finite() { return; }
        self.rest_x += dx.clamp(-4000.0, 4000.0);
        self.rest_y += dy.clamp(-4000.0, 4000.0);
        let (ix, iy) = (self.rest_x.trunc() as i32, self.rest_y.trunc() as i32);
        if ix == 0 && iy == 0 { return; }
        self.rest_x -= ix as f64;
        self.rest_y -= iy as f64;
        match sink.cursor() {
            Some(((x, y), _)) => {
                let (tx, ty) = (x + ix, y + iy);
                let (l, t, r, b) = sink.screen_at(tx, ty);
                let (tx, ty) = (tx.clamp(l, r - 1), ty.clamp(t, b - 1));
                if (tx, ty) != (x, y) { sink.send(&[Ev::Move { x: tx, y: ty, relative: false }]); }
            }
            None => sink.send(&[Ev::Move { x: ix, y: iy, relative: true }]),
        }
    }

    pub fn button(&mut self, sink: &mut dyn Sink, b: Button, press: Press) {
        let (down, up) = (Ev::Button { b, down: true }, Ev::Button { b, down: false });
        match press {
            Press::Down => sink.send(&[down]),
            Press::Up => sink.send(&[up]),
            Press::Click => sink.send(&[down, up]),
            Press::Dbl => sink.send(&[down.clone(), up.clone(), down, up]),
        }
    }

    /// Wheel units (120 a notch); positive y scrolls up (away from the user), positive x to the right.
    pub fn scroll(&mut self, sink: &mut dyn Sink, dx: f64, dy: f64) {
        if !dx.is_finite() || !dy.is_finite() { return; }
        self.wheel_x += dx.clamp(-12000.0, 12000.0);
        self.wheel_y += dy.clamp(-12000.0, 12000.0);
        let mut events = Vec::new();
        let (ix, iy) = (self.wheel_x.trunc() as i32, self.wheel_y.trunc() as i32);
        if iy != 0 {
            self.wheel_y -= iy as f64;
            events.push(Ev::Wheel { delta: iy, horizontal: false });
        }
        if ix != 0 {
            self.wheel_x -= ix as f64;
            events.push(Ev::Wheel { delta: ix, horizontal: true });
        }
        if !events.is_empty() { sink.send(&events); }
    }

    /// Ctrl + wheel, in notches; whole notches only (most programs zoom one step per notch).
    pub fn zoom(&mut self, sink: &mut dyn Sink, notches: f64) {
        if !notches.is_finite() { return; }
        self.zoom += notches.clamp(-20.0, 20.0);
        let whole = self.zoom.trunc() as i32;
        if whole == 0 { return; }
        self.zoom -= whole as f64;
        let ctrl = keys::lookup("ctrl").unwrap();
        sink.send(&[
            Ev::Key { vk: ctrl, down: true },
            Ev::Wheel { delta: whole * 120, horizontal: false },
            Ev::Key { vk: ctrl, down: false },
        ]);
    }

    pub fn text(&mut self, sink: &mut dyn Sink, text: &str) {
        let mut events = Vec::new();
        for ch in text.chars() {
            let named = match ch {
                '\n' => Some("enter"),
                '\t' => Some("tab"),
                '\u{8}' => Some("backspace"),
                '\r' => continue,
                _ => None,
            };
            if let Some(name) = named {
                let vk = keys::lookup(name).unwrap();
                events.push(Ev::Key { vk, down: true });
                events.push(Ev::Key { vk, down: false });
                continue;
            }
            let mut buf = [0u16; 2];
            for &unit in ch.encode_utf16(&mut buf).iter() {
                events.push(Ev::Unicode { unit, down: true });
                events.push(Ev::Unicode { unit, down: false });
            }
        }
        if !events.is_empty() { sink.send(&events); }
    }

    /// A named key with modifiers held around it. Unknown names are an error for the phone to show.
    pub fn key(&mut self, sink: &mut dyn Sink, name: &str, mods: &[String], press: Press) -> Result<(), String> {
        let vk = keys::lookup(name).ok_or_else(|| format!("Tecla desconocida: {name}"))?;
        let mut held = Vec::new();
        for m in mods {
            let mvk = keys::lookup(m).filter(|v| keys::is_modifier(*v)).ok_or_else(|| format!("Modificador desconocido: {m}"))?;
            if !held.contains(&mvk) && mvk != vk { held.push(mvk); }
        }
        let mut events: Vec<Ev> = held.iter().map(|&m| Ev::Key { vk: m, down: true }).collect();
        match press {
            Press::Down => events.push(Ev::Key { vk, down: true }),
            Press::Up => events.push(Ev::Key { vk, down: false }),
            Press::Click | Press::Dbl => {
                let times = if press == Press::Dbl { 2 } else { 1 };
                for _ in 0..times {
                    events.push(Ev::Key { vk, down: true });
                    events.push(Ev::Key { vk, down: false });
                }
            }
        }
        events.extend(held.iter().rev().map(|&m| Ev::Key { vk: m, down: false }));
        sink.send(&events);
        Ok(())
    }
}

/// Absolute coordinates for SendInput: 0..65535 across the whole virtual desktop.
pub fn normalize(value: i32, origin: i32, size: i32) -> i32 {
    if size <= 1 { return 0; }
    let offset = (value - origin).clamp(0, size - 1) as i64;
    ((offset * 65535 + (size as i64 - 1) / 2) / (size as i64 - 1)) as i32
}

#[cfg(windows)]
pub use win::SendInputSink;

#[cfg(windows)]
mod win {
    use super::*;
    use std::mem::size_of;
    use windows::Win32::Foundation::POINT;
    use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST};
    use windows::Win32::UI::Input::KeyboardAndMouse::*;
    use windows::Win32::UI::WindowsAndMessaging::{
        GetCursorPos, GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
    };

    pub struct SendInputSink;

    fn mouse(dx: i32, dy: i32, data: i32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
        INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 },
            },
        }
    }

    fn keyboard(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 },
            },
        }
    }

    impl Sink for SendInputSink {
        fn send(&mut self, events: &[Ev]) {
            let inputs: Vec<INPUT> = events
                .iter()
                .map(|ev| match *ev {
                    Ev::Move { x, y, relative: true } => mouse(x, y, 0, MOUSEEVENTF_MOVE),
                    Ev::Move { x, y, relative: false } => unsafe {
                        let (vx, vy) = (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN));
                        let (vw, vh) = (GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));
                        mouse(
                            normalize(x, vx, vw),
                            normalize(y, vy, vh),
                            0,
                            MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                        )
                    },
                    Ev::Button { b, down } => {
                        let (flags, data) = match (b, down) {
                            (Button::Left, true) => (MOUSEEVENTF_LEFTDOWN, 0),
                            (Button::Left, false) => (MOUSEEVENTF_LEFTUP, 0),
                            (Button::Right, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
                            (Button::Right, false) => (MOUSEEVENTF_RIGHTUP, 0),
                            (Button::Middle, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
                            (Button::Middle, false) => (MOUSEEVENTF_MIDDLEUP, 0),
                            (Button::X1, true) => (MOUSEEVENTF_XDOWN, 1),
                            (Button::X1, false) => (MOUSEEVENTF_XUP, 1),
                            (Button::X2, true) => (MOUSEEVENTF_XDOWN, 2),
                            (Button::X2, false) => (MOUSEEVENTF_XUP, 2),
                        };
                        mouse(0, 0, data, flags)
                    }
                    Ev::Wheel { delta, horizontal } => {
                        mouse(0, 0, delta, if horizontal { MOUSEEVENTF_HWHEEL } else { MOUSEEVENTF_WHEEL })
                    }
                    Ev::Key { vk, down } => {
                        let scan = unsafe { MapVirtualKeyW(vk.code as u32, MAPVK_VK_TO_VSC) } as u16;
                        let mut flags = KEYBD_EVENT_FLAGS(0);
                        if vk.extended { flags |= KEYEVENTF_EXTENDEDKEY; }
                        if !down { flags |= KEYEVENTF_KEYUP; }
                        keyboard(vk.code, scan, flags)
                    }
                    Ev::Unicode { unit, down } => {
                        let mut flags = KEYEVENTF_UNICODE;
                        if !down { flags |= KEYEVENTF_KEYUP; }
                        keyboard(0, unit, flags)
                    }
                })
                .collect();
            if !inputs.is_empty() {
                unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) };
            }
        }

        fn cursor(&mut self) -> Option<((i32, i32), (i32, i32, i32, i32))> {
            let mut p = POINT::default();
            unsafe { GetCursorPos(&mut p) }.ok()?;
            Some(((p.x, p.y), self.screen_at(p.x, p.y)))
        }

        fn screen_at(&mut self, x: i32, y: i32) -> (i32, i32, i32, i32) {
            unsafe {
                let monitor = MonitorFromPoint(POINT { x, y }, MONITOR_DEFAULTTONEAREST);
                let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
                if GetMonitorInfoW(monitor, &mut info).as_bool() {
                    let r = info.rcMonitor;
                    (r.left, r.top, r.right, r.bottom)
                } else {
                    let (vx, vy) = (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN));
                    (vx, vy, vx + GetSystemMetrics(SM_CXVIRTUALSCREEN), vy + GetSystemMetrics(SM_CYVIRTUALSCREEN))
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two 1920x1080 screens side by side, the second one 200 px lower.
    struct Fake { events: Vec<Ev>, at: Option<(i32, i32)> }

    impl Sink for Fake {
        fn send(&mut self, events: &[Ev]) {
            for ev in events {
                if let Ev::Move { x, y, relative: false } = ev { self.at = Some((*x, *y)); }
            }
            self.events.extend_from_slice(events);
        }
        fn cursor(&mut self) -> Option<((i32, i32), (i32, i32, i32, i32))> {
            let at = self.at?;
            Some((at, self.screen_at(at.0, at.1)))
        }
        fn screen_at(&mut self, x: i32, _y: i32) -> (i32, i32, i32, i32) {
            if x < 1920 { (0, 0, 1920, 1080) } else { (1920, 200, 3840, 1280) }
        }
    }

    fn fake() -> Fake { Fake { events: vec![], at: Some((100, 100)) } }

    #[test]
    fn fractions_add_up() {
        let (mut inj, mut sink) = (Injector::default(), fake());
        inj.move_by(&mut sink, 0.4, 0.0);
        inj.move_by(&mut sink, 0.4, 0.0);
        assert!(sink.events.is_empty());
        inj.move_by(&mut sink, 0.4, -1.5);
        assert_eq!(sink.events, vec![Ev::Move { x: 101, y: 99, relative: false }]);
    }

    #[test]
    fn stays_inside_the_screens() {
        let (mut inj, mut sink) = (Injector::default(), fake());
        inj.move_by(&mut sink, -500.0, -500.0);
        assert_eq!(sink.at, Some((0, 0)));
        // into the second screen, which starts lower: clamped to its top
        sink.at = Some((1900, 50));
        inj.move_by(&mut sink, 100.0, 0.0);
        assert_eq!(sink.at, Some((2000, 200)));
        // pushing against an edge sends nothing
        sink.events.clear();
        sink.at = Some((0, 0));
        inj.move_by(&mut sink, -10.0, 0.0);
        assert!(sink.events.is_empty());
    }

    #[test]
    fn relative_without_a_cursor() {
        let mut inj = Injector::default();
        let mut sink = Fake { events: vec![], at: None };
        inj.move_by(&mut sink, 3.7, -2.2);
        assert_eq!(sink.events, vec![Ev::Move { x: 3, y: -2, relative: true }]);
        inj.move_by(&mut sink, f64::NAN, 1.0);
        assert_eq!(sink.events.len(), 1);
    }

    #[test]
    fn smooth_wheel() {
        let (mut inj, mut sink) = (Injector::default(), fake());
        inj.scroll(&mut sink, 0.0, 30.5);
        inj.scroll(&mut sink, 0.0, 30.5);
        assert_eq!(sink.events, vec![
            Ev::Wheel { delta: 30, horizontal: false },
            Ev::Wheel { delta: 31, horizontal: false },
        ]);
    }

    #[test]
    fn zoom_whole_notches_with_ctrl() {
        let (mut inj, mut sink) = (Injector::default(), fake());
        inj.zoom(&mut sink, 0.6);
        assert!(sink.events.is_empty());
        inj.zoom(&mut sink, 0.6);
        let ctrl = keys::lookup("ctrl").unwrap();
        assert_eq!(sink.events, vec![
            Ev::Key { vk: ctrl, down: true },
            Ev::Wheel { delta: 120, horizontal: false },
            Ev::Key { vk: ctrl, down: false },
        ]);
    }

    #[test]
    fn text_as_unicode_and_enter() {
        let (mut inj, mut sink) = (Injector::default(), fake());
        inj.text(&mut sink, "ñ\n😀");
        let enter = keys::lookup("enter").unwrap();
        assert_eq!(sink.events, vec![
            Ev::Unicode { unit: 0xF1, down: true },
            Ev::Unicode { unit: 0xF1, down: false },
            Ev::Key { vk: enter, down: true },
            Ev::Key { vk: enter, down: false },
            Ev::Unicode { unit: 0xD83D, down: true },
            Ev::Unicode { unit: 0xD83D, down: false },
            Ev::Unicode { unit: 0xDE00, down: true },
            Ev::Unicode { unit: 0xDE00, down: false },
        ]);
    }

    #[test]
    fn shortcuts_hold_modifiers_in_order() {
        let (mut inj, mut sink) = (Injector::default(), fake());
        inj.key(&mut sink, "t", &["ctrl".into(), "shift".into()], Press::Click).unwrap();
        let (c, s, t) = (keys::lookup("ctrl").unwrap(), keys::lookup("shift").unwrap(), keys::lookup("t").unwrap());
        assert_eq!(sink.events, vec![
            Ev::Key { vk: c, down: true },
            Ev::Key { vk: s, down: true },
            Ev::Key { vk: t, down: true },
            Ev::Key { vk: t, down: false },
            Ev::Key { vk: s, down: false },
            Ev::Key { vk: c, down: false },
        ]);
        assert!(inj.key(&mut sink, "nada", &[], Press::Click).is_err());
        assert!(inj.key(&mut sink, "a", &["b".into()], Press::Click).is_err());
    }

    #[test]
    fn double_click() {
        let (mut inj, mut sink) = (Injector::default(), fake());
        inj.button(&mut sink, Button::Left, Press::Dbl);
        assert_eq!(sink.events.len(), 4);
    }

    #[test]
    fn normalizes_to_the_virtual_desktop() {
        assert_eq!(normalize(0, 0, 1920), 0);
        assert_eq!(normalize(1919, 0, 1920), 65535);
        assert_eq!(normalize(-1920, -1920, 3840), 0);
        assert_eq!(normalize(5000, 0, 1920), 65535);
        // every pixel lands on its own value and comes back to the same pixel
        for x in 0..1920 {
            let n = normalize(x, 0, 1920) as i64;
            let back = (n * 1919 + 32767) / 65535;
            assert_eq!(back, x as i64);
        }
    }
}
