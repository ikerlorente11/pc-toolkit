//! YouTube Music (proof of concept): a song one does not have, played straight from it, without downloading it nor
//! any server. `media://y/q?artist=…&title=…&d=<seconds>`: found on YouTube Music (its «songs»), its audio's address
//! asked for (YouTube's own API, as yt-dlp's visionOS client does, with a visitor's data and cookies taken once from a
//! video's page) and the audio relayed by pieces, as the cloud's songs are (so it can seek, and goes through the page's
//! sound circuit: the equaliser, the same loudness).
//!
//! What is found is kept for this run: the song's video (by its artist and title) and its audio's address (until a
//! little before it expires, ~6 h). Each step's time goes to the log (`yt:`), to see how long a song takes to sound.
//!
//! So a song sounds at once, the page has the songs it shows prepared beforehand (`yt_prepare`): found, their audio's
//! address asked for and its first piece fetched (YouTube is slow to give a song's first bytes the first time: 0.5–5 s)
//! and kept, then given at once when it plays; the rest comes while it sounds.

use std::borrow::Cow;
use std::collections::HashMap;
use std::io::Read;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::http::{Request, Response};
use tauri::{AppHandle, Manager, Runtime};

/// YouTube's visionOS client (yt-dlp's `visionos`): it gives the audio's address without a JS player nor a PO token
const VISION_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15";
/// a video whose page gives the visitor's data (any will do)
const FIRST_VISIT: &str = "https://www.youtube.com/watch?v=KUZ7jG7BKE8";
/// YouTube Music's search, only songs
const SONGS_ONLY: &str = "EgWKAQIIAWoKEAkQBRAKEAMQBA==";
/// a visit lasts this long before another is made
const SESSION_FOR: Duration = Duration::from_secs(3600);

struct Session {
    visitor: String,
    cookies: String,
    made: Instant,
}

#[derive(Default)]
pub struct Yt {
    session: Mutex<Option<Session>>,
    /// «artist\ntitle» → its video (None: not found)
    found: Mutex<HashMap<String, Option<String>>>,
    /// video → its audio's address, its size and until when it is good
    audio: Mutex<HashMap<String, (String, u64, Instant)>>,
    /// video → its audio's first piece (fetched beforehand) and the whole's size; the order they came in (the oldest go)
    first: Mutex<(HashMap<String, (Vec<u8>, u64, String)>, Vec<String>)>,
    /// songs being prepared now («artist\ntitle»)
    preparing: Mutex<std::collections::HashSet<String>>,
}

/// the first piece kept of each song prepared, and how many songs keep theirs
const FIRST_PIECE: u64 = 256 << 10;
const FIRST_KEPT: usize = 60;
/// songs prepared at once
const PREPARING_AT_ONCE: usize = 3;

/// A song the page shows, to prepare (as `media://y/q` finds it).
#[derive(serde::Deserialize, Clone)]
pub struct Wanted {
    artist: String,
    title: String,
    #[serde(default)]
    d: f64,
    #[serde(default)]
    isrc: Option<String>,
}

/// Found, its address asked for and its first piece fetched and kept (nothing if it already was).
fn prepare_one(yt: &Yt, w: &Wanted) -> Result<(), String> {
    let video = search(yt, &w.artist, &w.title, w.d as u64, w.isrc.as_deref().unwrap_or(""))?;
    if yt.first.lock().unwrap().0.contains_key(&video) {
        return Ok(());
    }
    let (url, _) = audio(yt, &video)?;
    let t = Instant::now();
    let res = agent().get(&url).set("User-Agent", VISION_UA).set("Range", &format!("bytes=0-{}", FIRST_PIECE - 1)).call().map_err(|e| e.to_string())?;
    let total = res.header("Content-Range").and_then(|v| v.rsplit('/').next()).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
    let kind = res.header("Content-Type").unwrap_or("audio/webm").to_string();
    let mut body = vec![];
    res.into_reader().take(FIRST_PIECE).read_to_end(&mut body).map_err(|e| e.to_string())?;
    eprintln!("yt: preparada {video} ({} KB en {} ms)", body.len() / 1024, t.elapsed().as_millis());
    let mut first = yt.first.lock().unwrap();
    first.0.insert(video.clone(), (body, total, kind));
    first.1.push(video);
    while first.1.len() > FIRST_KEPT {
        let old = first.1.remove(0);
        first.0.remove(&old);
    }
    Ok(())
}

/// Prepares the songs the page shows (the first ones first), a few at once, away from the page.
#[tauri::command]
pub fn yt_prepare<R: Runtime>(app: AppHandle<R>, songs: Vec<Wanted>) {
    std::thread::spawn(move || {
        let yt = app.state::<Yt>();
        let todo: Vec<Wanted> = {
            let mut busy = yt.preparing.lock().unwrap();
            songs.into_iter().take(30).filter(|w| busy.insert(format!("{}\n{}", w.artist, w.title))).collect()
        };
        for chunk in todo.chunks(PREPARING_AT_ONCE) {
            std::thread::scope(|s| {
                for w in chunk {
                    let yt = &yt;
                    s.spawn(move || {
                        if let Err(e) = prepare_one(yt, w) { eprintln!("yt: no se pudo preparar «{} – {}»: {e}", w.artist, w.title) }
                        yt.preparing.lock().unwrap().remove(&format!("{}\n{}", w.artist, w.title));
                    });
                }
            });
        }
    });
}

fn agent() -> ureq::Agent {
    static AGENT: std::sync::OnceLock<ureq::Agent> = std::sync::OnceLock::new();
    AGENT
        .get_or_init(|| ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(10)).timeout_read(Duration::from_secs(30)).build())
        .clone()
}

/// The visitor's data and cookies of a first visit (once an hour, or when YouTube asks again).
fn session(yt: &Yt, fresh: bool) -> Result<(String, String), String> {
    let mut guard = yt.session.lock().unwrap();
    if let Some(s) = guard.as_ref().filter(|s| !fresh && s.made.elapsed() < SESSION_FOR) {
        return Ok((s.visitor.clone(), s.cookies.clone()));
    }
    let t = Instant::now();
    let res = agent().get(FIRST_VISIT).set("User-Agent", VISION_UA).set("Accept-Language", "es-ES,es;q=0.9").call().map_err(|e| e.to_string())?;
    let cookies = res.all("set-cookie").iter().filter_map(|c| c.split(';').next()).collect::<Vec<_>>().join("; ");
    let html = res.into_string().map_err(|e| e.to_string())?;
    let visitor = html.split("\"VISITOR_DATA\":\"").nth(1).and_then(|r| r.split('"').next()).unwrap_or_default().to_string();
    if visitor.is_empty() {
        return Err("YouTube no dio datos de visitante".into());
    }
    eprintln!("yt: visita {} ms", t.elapsed().as_millis());
    *guard = Some(Session { visitor: visitor.clone(), cookies: cookies.clone(), made: Instant::now() });
    Ok((visitor, cookies))
}

fn text(runs: &Value) -> String {
    runs["runs"].as_array().map(|r| r.iter().filter_map(|x| x["text"].as_str()).collect::<String>()).unwrap_or_default()
}
fn plain(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect()
}
/// «3:25» → 205
fn seconds(s: &str) -> u64 {
    s.split(':').fold(0, |acc, p| acc * 60 + p.trim().parse::<u64>().unwrap_or(0))
}

/// YouTube Music's first songs for a search: their video, title, «Artist • Album • 3:25» and length.
fn songs_for(query: &str) -> Result<Vec<(String, String, String, u64)>, String> {
    let body = json!({
        "context": { "client": { "clientName": "WEB_REMIX", "clientVersion": "1.20251119.01.00", "hl": "es", "gl": "ES" } },
        "query": query,
        "params": SONGS_ONLY
    });
    let data: Value = agent().post("https://music.youtube.com/youtubei/v1/search?prettyPrint=false")
        .set("Content-Type", "application/json").send_string(&body.to_string()).map_err(|e| e.to_string())?
        .into_json().map_err(|e| e.to_string())?;
    let mut hits = vec![];
    let shelves = &data["contents"]["tabbedSearchResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"];
    for shelf in shelves.as_array().into_iter().flatten() {
        for item in shelf["musicShelfRenderer"]["contents"].as_array().into_iter().flatten() {
            let r = &item["musicResponsiveListItemRenderer"];
            let Some(id) = r["playlistItemData"]["videoId"].as_str() else { continue };
            let cols: Vec<String> = r["flexColumns"].as_array().into_iter().flatten()
                .map(|c| text(&c["musicResponsiveListItemFlexColumnRenderer"]["text"])).collect();
            let meta = cols.get(1).cloned().unwrap_or_default();
            let length = meta.rsplit(" • ").next().map(seconds).unwrap_or(0);
            hits.push((id.to_string(), cols.first().cloned().unwrap_or_default(), meta, length));
        }
    }
    Ok(hits)
}

/// The song's video on YouTube Music: by its ISRC (the recording's own code: that very version) if a result as long
/// comes; else, among the first songs for «artist title», the one most alike (its artist, its title, its length).
fn search(yt: &Yt, artist: &str, title: &str, duration: u64, isrc: &str) -> Result<String, String> {
    let key = format!("{artist}\n{title}\n{isrc}");
    if let Some(found) = yt.found.lock().unwrap().get(&key) {
        return found.clone().ok_or_else(|| "no está en YouTube Music".into());
    }
    let t = Instant::now();
    let close = |length: u64, by: u64| duration == 0 || length == 0 || length.abs_diff(duration) <= by;
    let mut best = None;
    let mut how = "";
    if !isrc.is_empty() {
        if let Ok(hits) = songs_for(isrc) {
            best = hits.iter().take(3).find(|h| close(h.3, 5)).map(|h| h.0.clone());
            how = "ISRC";
        }
    }
    if best.is_none() {
        let hits = songs_for(&format!("{artist} {title}"))?;
        let (wanted_artist, wanted_title) = (plain(artist), plain(title));
        let score = |h: &(String, String, String, u64)| {
            let mut n = 0;
            if plain(&h.2).contains(&wanted_artist) { n += 2 }
            let found = plain(&h.1);
            if !found.is_empty() && (found.contains(&wanted_title) || wanted_title.contains(&found)) { n += 2 }
            if duration > 0 && h.3 > 0 { n += if h.3.abs_diff(duration) <= 3 { 2 } else if h.3.abs_diff(duration) <= 8 { 1 } else { 0 } }
            n
        };
        // the most alike of the first five (the first of them on a tie)
        best = hits.iter().take(5).enumerate().max_by_key(|(i, h)| (score(h), std::cmp::Reverse(*i))).map(|(_, h)| h.0.clone());
        how = "artista y título";
    }
    eprintln!("yt: buscar «{artist} – {title}» ({how}) {} ms → {}", t.elapsed().as_millis(), best.as_deref().unwrap_or("nada"));
    yt.found.lock().unwrap().insert(key, best.clone());
    best.ok_or_else(|| "no está en YouTube Music".into())
}

/// The video's audio (opus, the best): its address and size, kept until a little before it expires.
fn audio(yt: &Yt, video: &str) -> Result<(String, u64), String> {
    if let Some((url, size, until)) = yt.audio.lock().unwrap().get(video) {
        if Instant::now() < *until {
            return Ok((url.clone(), *size));
        }
    }
    for retry in [false, true] {
        let (visitor, cookies) = session(yt, retry)?;
        let t = Instant::now();
        let body = json!({
            "context": { "client": { "clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple", "deviceModel": "RealityDevice17,1",
                                     "userAgent": VISION_UA, "osName": "visionOS", "osVersion": "26.5.23O471", "hl": "es", "gl": "ES",
                                     "visitorData": visitor } },
            "videoId": video, "contentCheckOk": true, "racyCheckOk": true
        });
        let data: Value = agent().post("https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
            .set("Content-Type", "application/json").set("User-Agent", VISION_UA).set("X-YouTube-Client-Name", "101")
            .set("X-YouTube-Client-Version", "1.02").set("X-Goog-Visitor-Id", &visitor).set("Cookie", &cookies)
            .send_string(&body.to_string()).map_err(|e| e.to_string())?
            .into_json().map_err(|e| e.to_string())?;
        let status = data["playabilityStatus"]["status"].as_str().unwrap_or("");
        if status != "OK" {
            eprintln!("yt: audio {video} {} ms: {status} {}", t.elapsed().as_millis(), data["playabilityStatus"]["reason"].as_str().unwrap_or(""));
            // asked to sign in (a visit too old, or seen as a bot): once more with a new visit
            if status == "LOGIN_REQUIRED" && !retry {
                continue;
            }
            return Err(format!("YouTube no la da: {}", data["playabilityStatus"]["reason"].as_str().unwrap_or(status)));
        }
        let formats = data["streamingData"]["adaptiveFormats"].as_array().cloned().unwrap_or_default();
        let mut audio: Vec<&Value> = formats.iter().filter(|f| f["mimeType"].as_str().is_some_and(|m| m.starts_with("audio/")) && f["url"].is_string()).collect();
        audio.sort_by_key(|f| (!f["mimeType"].as_str().unwrap_or("").contains("opus"), -(f["bitrate"].as_i64().unwrap_or(0))));
        let f = audio.first().ok_or("YouTube no dio su audio")?;
        let url = f["url"].as_str().unwrap_or("").to_string();
        let size = f["contentLength"].as_str().and_then(|s| s.parse().ok()).unwrap_or(0);
        let expires = data["streamingData"]["expiresInSeconds"].as_str().and_then(|s| s.parse::<u64>().ok()).unwrap_or(3600);
        eprintln!("yt: audio {video} {} ms (itag {}, {} kbps)", t.elapsed().as_millis(), f["itag"], f["bitrate"].as_i64().unwrap_or(0) / 1000);
        let until = Instant::now() + Duration::from_secs(expires.saturating_sub(600));
        yt.audio.lock().unwrap().insert(video.to_string(), (url.clone(), size, until));
        return Ok((url, size));
    }
    Err("YouTube no la da".into())
}

/// `/y/q?artist=…&title=…&d=…` (or `/y/v/<video>`): the piece of the song's audio the element asks for.
pub fn answer<R: Runtime>(app: &AppHandle<R>, path: &str, request: &Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    let fail = |code: u16, why: String| {
        eprintln!("yt: {why}");
        Response::builder().status(code).header("Content-Type", "text/plain; charset=utf-8").header("Access-Control-Allow-Origin", "*")
            .header("Cache-Control", "no-store").body(Cow::Owned(why.into_bytes())).unwrap()
    };
    let yt = app.state::<Yt>();
    let t = Instant::now();
    let video = if let Some(id) = path.strip_prefix("v/") {
        id.to_string()
    } else {
        let query: HashMap<String, String> = request.uri().query().unwrap_or("").split('&')
            .filter_map(|p| p.split_once('=')).map(|(k, v)| (k.to_string(), crate::library::percent_decode(&v.replace('+', " ")))).collect();
        let (artist, title) = (query.get("artist").cloned().unwrap_or_default(), query.get("title").cloned().unwrap_or_default());
        let duration = query.get("d").and_then(|d| d.parse::<f64>().ok()).unwrap_or(0.0) as u64;
        match search(&yt, &artist, &title, duration, query.get("isrc").map(String::as_str).unwrap_or("")) {
            Ok(v) => v,
            Err(e) => return fail(404, e),
        }
    };
    let (url, _) = match audio(&yt, &video) {
        Ok(a) => a,
        Err(e) => return fail(502, e),
    };
    let asked = request.headers().get("range").and_then(|v| v.to_str().ok()).unwrap_or("bytes=0-").to_string();
    // its start, prepared beforehand: at once (the element asks for the rest after it)
    if asked.trim().starts_with("bytes=0-") {
        if let Some((piece, total, kind)) = yt.first.lock().unwrap().0.get(&video) {
            eprintln!("yt: principio de {video} ya preparado: {} KB en {} ms", piece.len() / 1024, t.elapsed().as_millis());
            return Response::builder().status(206)
                .header("Accept-Ranges", "bytes").header("Access-Control-Allow-Origin", "*").header("Access-Control-Expose-Headers", "Content-Range")
                .header("Cache-Control", "no-store").header("Content-Type", kind.clone())
                .header("Content-Range", format!("bytes 0-{}/{}", piece.len().saturating_sub(1), total))
                .header("Content-Length", piece.len()).body(Cow::Owned(piece.clone())).unwrap();
        }
    }
    let range = crate::cloud::limit_range(&asked);
    let res = match agent().get(&url).set("User-Agent", VISION_UA).set("Range", &range).call() {
        Ok(r) => r,
        Err(ureq::Error::Status(code, _)) => {
            // the address no longer serves (expired early): forgotten, so the next piece asks for another
            yt.audio.lock().unwrap().remove(&video);
            return fail(code, format!("el audio de {video} respondió {code}"));
        }
        Err(e) => return fail(502, e.to_string()),
    };
    let mut builder = Response::builder()
        .status(res.status())
        .header("Accept-Ranges", "bytes")
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Expose-Headers", "Content-Range")
        .header("Cache-Control", "no-store")
        .header("Content-Type", res.header("Content-Type").unwrap_or("audio/webm").to_string());
    if let Some(v) = res.header("Content-Range") {
        builder = builder.header("Content-Range", v.to_string());
    }
    let mut body = vec![];
    if res.into_reader().take(crate::cloud::RANGE_PIECE + 1).read_to_end(&mut body).is_err() {
        return fail(502, "el audio se cortó".into());
    }
    eprintln!("yt: trozo {range} de {video}: {} KB en {} ms", body.len() / 1024, t.elapsed().as_millis());
    builder.header("Content-Length", body.len()).body(Cow::Owned(body)).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lengths() {
        assert_eq!(seconds("3:25"), 205);
        assert_eq!(seconds("1:02:03"), 3723);
        assert_eq!(plain("AC/DC"), "acdc");
    }
}
