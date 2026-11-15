//! The server phones talk to: `GET /info` (so the phone finds this PC scanning its network) and
//! `GET /ws`, the WebSocket each phone controls the PC through.
//!
//! Handshake: the PC says hi with a random challenge; the phone answers "hello" (paired) or "pair"
//! (new) with a box holding that challenge; from then on every frame both ways is a sealed box
//! (crypto.rs). See PROTOCOL.md in the puntero repo.

use crate::crypto::{self, SecretKey};
use crate::input::{Injector, Sink};
use crate::protocol::{self, Button, Command, Event, Hello, HelloBox, PairVia, Press};
use crate::state::State;
use crate::system;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State as Shared};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::serve::ListenerExt;
use axum::{Json, Router};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use futures_util::{SinkExt, StreamExt};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::timeout;

/// The phone pings every few seconds; without anything for this long the session is dropped and
/// whatever it held pressed is let go.
const IDLE: Duration = Duration::from_secs(20);

pub async fn run(state: Arc<State>) {
    let port = state.config.lock().unwrap().port;
    let app = Router::new()
        .route("/info", get(info))
        .route("/ws", get(upgrade))
        .with_state(state.clone());
    let listener = match tokio::net::TcpListener::bind(("0.0.0.0", port)).await {
        Ok(listener) => listener,
        Err(e) => {
            *state.server.lock().unwrap() = Err(format!("No se puede usar el puerto {port}: {e}"));
            return;
        }
    };
    // pointer moves are tiny and frequent: no waiting to pack them together
    let listener = listener.tap_io(|tcp| { let _ = tcp.set_nodelay(true); });
    *state.server.lock().unwrap() = Ok(port);
    if let Err(e) = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await {
        *state.server.lock().unwrap() = Err(e.to_string());
    }
}

async fn info(Shared(state): Shared<Arc<State>>) -> impl IntoResponse {
    let id = state.config.lock().unwrap().pc_id.clone();
    Json(serde_json::json!({
        "app": "puntero",
        "v": protocol::VERSION,
        "id": id,
        "name": state.pc_name(),
        "version": env!("CARGO_PKG_VERSION"),
        "pairing": state.pairing_open(),
    }))
}

async fn upgrade(ws: WebSocketUpgrade, ConnectInfo(addr): ConnectInfo<SocketAddr>, Shared(state): Shared<Arc<State>>) -> impl IntoResponse {
    ws.max_message_size(1 << 20).on_upgrade(move |socket| session(socket, state, addr))
}

fn open_hello(key: &SecretKey, sealed: &str, challenge: &str) -> Option<HelloBox> {
    let frame = B64.decode(sealed).ok()?;
    let plain = crypto::open(key, &frame)?;
    let hello: HelloBox = serde_json::from_slice(&plain).ok()?;
    (hello.c == challenge).then_some(hello)
}

async fn deny(socket: &mut WebSocket, why: &str) {
    let _ = socket.send(Message::Text(serde_json::json!({ "t": "denied", "why": why }).to_string().into())).await;
    let _ = socket.send(Message::Close(None)).await;
}

/// Who the phone is and its key, or why not.
async fn handshake(socket: &mut WebSocket, state: &State) -> Option<(String, String, SecretKey, bool)> {
    let challenge = B64.encode(crypto::random::<16>());
    let pc_id = state.config.lock().unwrap().pc_id.clone();
    let hi = serde_json::json!({
        "t": "hi", "app": "puntero", "v": protocol::VERSION, "c": challenge, "name": state.pc_name(), "id": pc_id,
    });
    socket.send(Message::Text(hi.to_string().into())).await.ok()?;
    let text = match timeout(Duration::from_secs(15), socket.recv()).await {
        Ok(Some(Ok(Message::Text(text)))) => text,
        _ => return None,
    };
    let Ok(hello) = serde_json::from_str::<Hello>(&text) else {
        deny(socket, "bad").await;
        return None;
    };
    match hello {
        Hello::Hello { dev, sealed } => {
            let found = state.device_key(&dev).and_then(|key| open_hello(&key, &sealed, &challenge).map(|h| (key, h)));
            let Some((key, hello)) = found else {
                deny(socket, "unknown").await;
                return None;
            };
            Some((dev, hello.name, key, false))
        }
        Hello::Pair { dev, via, sealed } => {
            let Some(pair_key) = state.pairing_key(via) else {
                deny(socket, "closed").await;
                return None;
            };
            let Some(hello) = open_hello(&pair_key, &sealed, &challenge) else {
                state.pairing_failed();
                deny(socket, if via == PairVia::Code { "badcode" } else { "expired" }).await;
                return None;
            };
            let key: Option<SecretKey> = hello.key.as_deref().and_then(|k| B64.decode(k).ok()).and_then(|k| k.try_into().ok());
            let Some(key) = key else {
                deny(socket, "bad").await;
                return None;
            };
            state.add_device(&dev, &hello.name, &key);
            Some((dev, hello.name, key, true))
        }
    }
}

async fn session(mut socket: WebSocket, state: Arc<State>, addr: SocketAddr) {
    let Some((device, name, key, paired)) = handshake(&mut socket, &state).await else { return };
    state.device_seen(&device, &name);
    let session_id = state.session_start(&device, &name, addr.ip().to_string());
    let mut kicked = state.kick.subscribe();

    let (mut tx, mut rx) = socket.split();
    let (events, mut outbox) = mpsc::channel::<Event>(64);
    let writer = tokio::spawn(async move {
        while let Some(event) = outbox.recv().await {
            let Ok(json) = serde_json::to_vec(&event) else { continue };
            if tx.send(Message::Binary(crypto::seal(&key, &json).into())).await.is_err() { break; }
        }
        let _ = tx.send(Message::Close(None)).await;
    });

    let pc_id = state.config.lock().unwrap().pc_id.clone();
    let _ = events.send(Event::Welcome {
        name: state.pc_name(), id: pc_id, version: env!("CARGO_PKG_VERSION").into(), v: protocol::VERSION, paired: paired.then_some(true),
    }).await;
    send_volume(&events);

    let mut control = Control::default();
    loop {
        tokio::select! {
            message = timeout(IDLE, rx.next()) => {
                let frame = match message {
                    Ok(Some(Ok(Message::Binary(frame)))) => frame,
                    Ok(Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Text(_)))) => continue,
                    _ => break,   // closed, broken or silent for too long
                };
                let Some(plain) = crypto::open(&key, &frame) else { break };
                match serde_json::from_slice::<Command>(&plain) {
                    Ok(command) => control.handle(command, &events),
                    Err(e) => { let _ = events.try_send(Event::Error { msg: format!("No entiendo ese mensaje ({e})") }); }
                }
            }
            Ok(gone) = kicked.recv() => if gone == device { break },
        }
    }
    control.release();
    drop(events);
    let _ = writer.await;
    state.session_end(session_id);
}

fn send_volume(events: &mpsc::Sender<Event>) {
    let events = events.clone();
    tokio::task::spawn_blocking(move || {
        if let Ok((v, mute)) = system::volume::get() { let _ = events.try_send(Event::Vol { v, mute }); }
    });
}

/// Runs the slow ones (PowerShell, COM, window lists) off the async threads and sends the answer.
fn blocking(events: &mpsc::Sender<Event>, job: impl FnOnce() -> Result<Option<Event>, String> + Send + 'static) {
    let events = events.clone();
    tokio::task::spawn_blocking(move || {
        let event = match job() {
            Ok(Some(event)) => event,
            Ok(None) => return,
            Err(msg) => Event::Error { msg },
        };
        let _ = events.blocking_send(event);
    });
}

/// One phone's control of the pointer and keyboard, and what it holds pressed (let go when the
/// session ends, so a dropped connection never leaves a button or Ctrl stuck).
#[derive(Default)]
struct Control {
    injector: Injector,
    buttons: Vec<Button>,
    keys: Vec<String>,
}

#[cfg(windows)]
fn sink() -> impl Sink { crate::input::SendInputSink }

impl Control {
    fn handle(&mut self, command: Command, events: &mpsc::Sender<Event>) {
        let mut sink = sink();
        let error = |msg: String| { let _ = events.try_send(Event::Error { msg }); };
        match command {
            Command::Move { x, y } => self.injector.move_by(&mut sink, x, y),
            Command::Btn { b, a } => {
                match a {
                    Press::Down => if !self.buttons.contains(&b) { self.buttons.push(b) },
                    Press::Up => self.buttons.retain(|held| *held != b),
                    _ => {}
                }
                self.injector.button(&mut sink, b, a);
            }
            Command::Scroll { x, y } => self.injector.scroll(&mut sink, x, y),
            Command::Zoom { d } => self.injector.zoom(&mut sink, d),
            Command::Text { s } => self.injector.text(&mut sink, &s),
            Command::Key { k, mods, a } => {
                match a {
                    Press::Down => if !self.keys.contains(&k) { self.keys.push(k.clone()) },
                    Press::Up => self.keys.retain(|held| *held != k),
                    _ => {}
                }
                if let Err(msg) = self.injector.key(&mut sink, &k, &mods, a) { error(msg); }
                // the PC's own volume keys: tell the phone where the volume ended up
                if matches!(k.as_str(), "volup" | "voldown" | "mute") { send_volume(events); }
            }
            Command::Vol { v, mute } => blocking(events, move || {
                if v.is_some() || mute.is_some() { system::volume::set(v, mute)?; }
                let (v, mute) = system::volume::get()?;
                Ok(Some(Event::Vol { v, mute }))
            }),
            Command::Url { u } => blocking(events, move || system::open_url(&u).map(|_| None)),
            Command::Apps => blocking(events, || Ok(Some(Event::Apps { items: system::apps()? }))),
            Command::Launch { id } => blocking(events, move || system::launch(&id).map(|_| None)),
            Command::Windows => blocking(events, || Ok(Some(Event::Windows { items: system::windows_list::list() }))),
            Command::Win { id, a } => blocking(events, move || {
                system::windows_list::act(id, a)?;
                std::thread::sleep(Duration::from_millis(250));
                Ok(Some(Event::Windows { items: system::windows_list::list() }))
            }),
            Command::Power { a } => blocking(events, move || system::power(a).map(|_| None)),
            Command::Clip { s } => blocking(events, move || system::clipboard_set(&s).map(|_| None)),
            Command::Clipget => blocking(events, || Ok(Some(Event::Clip { s: system::clipboard_get()? }))),
            Command::Ping { n } => { let _ = events.try_send(Event::Pong { n }); }
        }
    }

    fn release(&mut self) {
        let mut sink = sink();
        for b in self.buttons.drain(..) { self.injector.button(&mut sink, b, Press::Up); }
        for k in std::mem::take(&mut self.keys) { let _ = self.injector.key(&mut sink, &k, &[], Press::Up); }
    }
}
