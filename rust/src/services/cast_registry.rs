//! The cast registry: discovered devices plus the small amount of state a
//! cast needs while it runs.
//!
//! State is in-memory and deliberately so. It is an agreed consequence of the
//! port swap that an in-flight cast is dropped at the moment of the swap - a
//! PostgreSQL table would add a staleness question nobody asked for, to solve
//! a one-time event.
//!
//! **A scan replaces the device map rather than merging into it.** That is
//! what makes discovery honest, and it is also why `resolve_device` has to
//! survive a device vanishing from a scan: mDNS windows miss devices in
//! roughly one scan in three, and a cast that is visibly running must stay
//! controllable.

use crate::services::cast_control::{self, SubtitleTrack};
use crate::services::cast_discovery;
use crate::services::cast_origin::{build_media_url, resolve_origin};
use crate::services::cast_transport::CastConnection;
use crate::services::dlna_service::{self, DlnaDevice};
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::{Mutex, RwLock};

/// What the client asked to play, remembered so `status` can describe it and
/// so a subtitle-offset change can re-issue the same load.
#[derive(Debug, Clone)]
pub struct ActiveCast {
    pub filename: String,
    pub origin: Option<String>,
    pub url: String,
    pub title: String,
    pub subtitle_offset: f64,
    /// Summaries only: the `src` of a Cast subtitle track is an absolute LAN
    /// URL, which is an internal detail the original also keeps out of
    /// `status`.
    pub subtitles: Vec<SubtitleSummary>,
    pub active_subtitle_id: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct SubtitleSummary {
    pub track_id: i64,
    pub label: String,
    pub lang: String,
}

impl ActiveCast {
    /// The `status` payload, minus `url` - a LAN URL is an internal detail and
    /// the original excludes it too.
    fn public_fields(&self) -> serde_json::Value {
        serde_json::json!({
            "filename": self.filename,
            "origin": self.origin,
            "title": self.title,
            "subtitle_offset": self.subtitle_offset,
            "subtitles": self
                .subtitles
                .iter()
                .map(|s| serde_json::to_value(s).unwrap_or(serde_json::Value::Null))
                .collect::<Vec<_>>(),
            "active_subtitle_id": self.active_subtitle_id,
        })
    }
}

#[derive(Default)]
struct Inner {
    devices: HashMap<String, serde_json::Value>,
    errors: HashMap<String, String>,
    active: HashMap<String, ActiveCast>,
    scanning: bool,
    scanned_at: Option<SystemTime>,
}

pub struct CastRegistry {
    inner: RwLock<Inner>,
    roots: Arc<Vec<std::path::PathBuf>>,
    cache_dir: Arc<std::path::PathBuf>,
    server_port: u16,
    /// Live Cast sessions, kept open between commands.
    ///
    /// Keyed by device id, and deliberately **not** dropped by a scan: mDNS
    /// windows miss a device in roughly one scan in three, and a visibly
    /// running cast must stay controllable. This is the same reason
    /// `resolve_device` falls back to active state.
    connections: Mutex<HashMap<String, CastConnection>>,
}

impl CastRegistry {
    pub fn new(
        roots: Arc<Vec<std::path::PathBuf>>,
        cache_dir: Arc<std::path::PathBuf>,
        server_port: u16,
    ) -> Arc<Self> {
        Arc::new(Self {
            inner: RwLock::new(Inner::default()),
            roots,
            cache_dir,
            server_port,
            connections: Mutex::new(HashMap::new()),
        })
    }

    /// The stored host for a device id, from the discovery cache only.
    ///
    /// Never taken from the request: a client-supplied host would be an SSRF
    /// pivot into an arbitrary TCP connection.
    async fn device_host(&self, device_id: &str) -> Option<String> {
        let inner = self.inner.read().await;
        let host = inner.devices.get(device_id)?["host"].as_str()?.to_string();
        if host.is_empty() {
            None
        } else {
            Some(host)
        }
    }

    /// A live connection for this device, dialling if necessary.
    async fn connection(
        self: &Arc<Self>,
        device_id: &str,
    ) -> Result<tokio::sync::MutexGuard<'_, HashMap<String, CastConnection>>, String> {
        let mut map = self.connections.lock().await;
        if !map.contains_key(device_id) {
            let host = self
                .device_host(device_id)
                .await
                .ok_or_else(|| "Unknown device - rescan and try again.".to_string())?;
            let conn = cast_control::connect_and_handshake(&host).await?;
            map.insert(device_id.to_string(), conn);
        }
        Ok(map)
    }

    async fn drop_connection(&self, device_id: &str) {
        if let Some(mut conn) = self.connections.lock().await.remove(device_id) {
            conn.close().await;
        }
    }

    /// Drop a dead connection and re-establish the media app session.
    ///
    /// A Cast connection dies on its own - the receiver resets the socket, or
    /// the virtual connection times out. A cached dead socket is the worst
    /// failure mode available: every later `seek`, `volume` and even `stop`
    /// fails with `os error 10053` and no retry, so the cast is permanently
    /// uncontrollable until the service restarts. Verified live: after one
    /// dropped session, `stop` could not be delivered at all.
    ///
    /// Re-establishing means re-running the app session too, because the
    /// `transportId` is per-session - a reconnect against a stale one is
    /// exactly the mistake that produced the original `CLOSE`.
    async fn redial(self: &Arc<Self>, device_id: &str) -> Result<(), String> {
        self.drop_connection(device_id).await;
        let mut conns = self.connection(device_id).await?;
        let conn = conns
            .get_mut(device_id)
            .ok_or_else(|| "could not open a Cast session".to_string())?;
        let transport = cast_control::ensure_media_receiver_session(conn).await?;
        conn.set_app_transport(transport);
        Ok(())
    }

    /// Run a Cast action, redialling once if the cached connection is dead.
    async fn cast_action(
        self: &Arc<Self>,
        device_id: &str,
        action: &str,
        value: Option<f64>,
    ) -> Result<(), String> {
        for attempt in 0..2 {
            let outcome = {
                let mut conns = self.connection(device_id).await?;
                match conns.get_mut(device_id) {
                    Some(conn) => dispatch_cast_action(conn, action, value).await,
                    None => Err("no Cast session is open".to_string()),
                }
            };
            match outcome {
                Ok(()) => return Ok(()),
                Err(e) if attempt == 0 => {
                    tracing::debug!(
                        "Cast {} on {} failed ({:?}); redialling once",
                        action,
                        device_id,
                        e
                    );
                    self.redial(device_id).await?;
                }
                Err(e) => return Err(e),
            }
        }
        Err("unreachable".to_string())
    }

    /// Read Cast status, redialling once if the cached connection is dead.
    async fn cast_status(self: &Arc<Self>, device_id: &str) -> Result<serde_json::Value, String> {
        for attempt in 0..2 {
            let outcome = {
                let mut conns = self.connection(device_id).await?;
                match conns.get_mut(device_id) {
                    Some(conn) => {
                        let (media, receiver) = cast_control::status(conn).await;
                        Ok(cast_control::status_payload(&media, &receiver))
                    }
                    None => Err("no Cast session is open".to_string()),
                }
            };
            match outcome {
                Ok(v) => return Ok(v),
                Err(e) if attempt == 0 => {
                    tracing::debug!("Cast status on {} failed ({:?}); redialling once", device_id, e);
                    self.redial(device_id).await?;
                }
                Err(e) => return Err(e),
            }
        }
        Err("unreachable".to_string())
    }

    /// Discovered devices. `?refresh=1` forces a scan; otherwise a cached list
    /// is returned and `scanning` tells the client to poll again.
    pub async fn devices(self: &Arc<Self>, force: bool) -> serde_json::Value {
        let mut start = false;
        {
            let mut inner = self.inner.write().await;
            let fresh = inner
                .scanned_at
                .map(dlna_service::is_fresh)
                .unwrap_or(false);
            if (force || !fresh) && !inner.scanning {
                inner.scanning = true;
                start = true;
            }
        }
        if start {
            let registry = Arc::clone(self);
            tokio::spawn(async move { registry.scan().await });
        }

        let inner = self.inner.read().await;
        let mut list: Vec<&serde_json::Value> = inner.devices.values().collect();
        // Sorted by (kind, name) so the picker order is stable between polls;
        // an unordered map makes the list jump around on every refresh.
        list.sort_by(|a, b| {
            let ka = a["kind"].as_str().unwrap_or("");
            let kb = b["kind"].as_str().unwrap_or("");
            let na = a["name"].as_str().unwrap_or("").to_lowercase();
            let nb = b["name"].as_str().unwrap_or("").to_lowercase();
            ka.cmp(kb).then(na.cmp(&nb))
        });
        serde_json::json!({
            // `ok` is part of the shape every other cast endpoint answers with,
            // and the web player's picker requires it.
            "ok": true,
            "devices": list,
            "scanning": inner.scanning,
            "errors": inner.errors,
            "scanned_at": inner.scanned_at
                .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0),
        })
    }

    async fn scan(self: Arc<Self>) {
        let mut found: HashMap<String, serde_json::Value> = HashMap::new();
        let mut errors: HashMap<String, String> = HashMap::new();

        match dlna_service::discover(Duration::from_secs(3)).await {
            Ok(devices) => {
                for d in devices {
                    found.insert(d.id.clone(), serde_json::to_value(&d).unwrap_or(serde_json::Value::Null));
                }
            }
            Err(e) => {
                tracing::warn!("DLNA discovery failed: {}", e);
                errors.insert("dlna".into(), e);
            }
        }

        // Cast discovery runs off hosts we already know: the DLNA renderers just
        // found, any Cast device a previous scan saw, and the neighbour table.
        // A TV that is both DLNA and Cast - the common case - therefore reaches
        // Cast discovery even if its neighbour entry has gone cold.
        let (dlna_pairs, cached_hosts) = {
            let inner = self.inner.read().await;
            let pairs: Vec<(String, String)> = inner
                .devices
                .values()
                .filter(|d| d["kind"].as_str() == Some("dlna"))
                .map(|d| {
                    (
                        d["host"].as_str().unwrap_or("").to_string(),
                        d["model"].as_str().unwrap_or("").to_string(),
                    )
                })
                .collect();
            let hosts: Vec<String> = inner
                .devices
                .values()
                .filter(|d| d["kind"].as_str() == Some("cast"))
                .map(|d| d["host"].as_str().unwrap_or("").to_string())
                .collect();
            (pairs, hosts)
        };
        let dlna_hosts: Vec<String> = dlna_pairs.iter().map(|(h, _)| h.clone()).collect();
        let candidates = cast_discovery::candidate_hosts(
            &dlna_hosts,
            &cached_hosts,
            &cast_discovery::neighbour_table(),
        );

        match cast_discovery::discover(candidates).await {
            Ok(mut devices) => {
                for d in &mut devices {
                    cast_discovery::enrich_model_from_dlna(d, &dlna_pairs);
                }
                for d in devices {
                    found.insert(d.id.clone(), serde_json::to_value(&d).unwrap_or(serde_json::Value::Null));
                }
            }
            Err(e) => {
                tracing::warn!("Cast discovery failed: {}", e);
                errors.insert("cast".into(), e);
            }
        }

        let mut inner = self.inner.write().await;
        // Replace, not merge: a device that stopped answering is gone. Cast
        // connections are the exception `resolve_device` papers over, because
        // mDNS windows miss a device in roughly one scan in three.
        inner.devices = found;
        inner.errors = errors;
        inner.scanned_at = Some(SystemTime::now());
        inner.scanning = false;
    }

    /// The discovered device, or a stand-in for one a scan just dropped.
    ///
    /// Without this a device a scan missed becomes "Unknown device - rescan and
    /// try again" while the phone is visibly casting to it.
    async fn resolve_device(&self, device_id: &str) -> Option<serde_json::Value> {
        let inner = self.inner.read().await;
        if let Some(d) = inner.devices.get(device_id) {
            return Some(d.clone());
        }
        inner.active.get(device_id).map(|a| {
            serde_json::json!({
                "id": device_id,
                "kind": "dlna",
                "name": a.title,
                "host": "",
            })
        })
    }

    /// Start a cast. Returns as soon as the request is accepted; the load
    /// itself runs detached, and a failure surfaces through `status` as
    /// `last_error` rather than leaving the remote stuck on "starting".
    pub async fn play(
        self: &Arc<Self>,
        device_id: &str,
        filename: &str,
        position: Option<f64>,
        origin: Option<&str>,
        subtitle_offset: Option<f64>,
        active_subtitle_id: Option<i64>,
    ) -> serde_json::Value {
        let device = match self.resolve_device(device_id).await {
            Some(d) => d,
            None => return err("Unknown device - rescan and try again."),
        };

        let path = match crate::services::path_resolver::PathResolver::resolve_media_path(filename, &self.roots) {
            Ok(p) => p,
            Err(_) => return err("Unknown media file."),
        };
        if !is_video(&path) {
            return err("Not a playable video file.");
        }

        let title = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| filename.to_string());
        let content_type = mime_guess::from_path(&path)
            .first_or_octet_stream()
            .to_string();

        let kind = device["kind"].as_str().unwrap_or("dlna").to_string();
        let origin_url = resolve_origin(origin, None, self.server_port);
        let base_origin = origin_url
            .clone()
            .unwrap_or_else(|| format!("http://{}:{}", dlna_service::lan_ip(), self.server_port));

        let dlna_device: Option<DlnaDevice> = serde_json::from_value(device.clone()).ok();

        // A Cast receiver plays only direct containers. Anything else needs an
        // HLS cache built first, and the receiver fetches it cross-origin -
        // which is why receiver CORS is scoped to /media/ and /hls/ exactly.
        let use_hls = kind == "cast" && cast_control::needs_hls(&path);
        if use_hls && self.hls_playlist(&path).is_none() {
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| format!(".{}", e))
                .unwrap_or_else(|| "this file".to_string());
            return err(&format!(
                "Chromecast cannot play {} directly. Open it once in the player to build an \
                 HLS version, then cast.",
                ext
            ));
        }
        let content_type = if use_hls { "application/x-mpegURL".into() } else { content_type };
        let title = if use_hls { format!("{} (transcoded)", title) } else { title };

        // Subtitle tracks must be fully-qualified: a receiver fetches them
        // itself and cannot resolve a relative path.
        let mut subtitle_tracks: Vec<SubtitleTrack> = Vec::new();
        let offset = subtitle_offset.unwrap_or(0.0);
        for (idx, track) in crate::services::subtitle_service::SubtitleService::list_tracks(
            &path,
            &self.rel_path(&path),
            &self.roots,
        )
        .into_iter()
        .enumerate()
        {
            let src = if track.src.starts_with("http://") || track.src.starts_with("https://") {
                track.src
            } else {
                format!("{}{}", base_origin, track.src)
            };
            let src = if offset != 0.0 {
                let sep = if src.contains('?') { "&" } else { "?" };
                format!("{}{}offset={:.3}", src, sep, offset)
            } else {
                src
            };
            subtitle_tracks.push(SubtitleTrack {
                track_id: idx as i64 + 1,
                label: if !track.label.is_empty() { track.label.clone() } else { track.name.clone() },
                lang: track.lang.clone(),
                src,
            });
        }
        let selected = active_subtitle_id
            .filter(|id| *id > 0)
            .or_else(|| subtitle_tracks.first().map(|t| t.track_id));

        let active = ActiveCast {
            filename: filename.to_string(),
            origin: origin.map(|s| s.to_string()),
            url: build_media_url(&self.rel_path(&path), origin_url.as_deref(), use_hls),
            title: title.clone(),
            subtitle_offset: offset,
            subtitles: subtitle_tracks
                .iter()
                .map(|t| SubtitleSummary { track_id: t.track_id, label: t.label.clone(), lang: t.lang.clone() })
                .collect(),
            active_subtitle_id: selected.unwrap_or(0),
        };

        {
            let mut inner = self.inner.write().await;
            inner.active.insert(device_id.to_string(), active.clone());
        }

        let registry = Arc::clone(self);
        let device_id_owned = device_id.to_string();
        let title_for_load = title.clone();
        let url_for_load = active.url.clone();
        let kind_for_load = kind.clone();
        tokio::spawn(async move {
            let result = match (kind_for_load.as_str(), dlna_device) {
                ("dlna", Some(d)) => {
                    let http = dlna_service::http_client(Duration::from_secs(8));
                    let (size, duration) = dlna_service::size_and_duration(&path).await;
                    dlna_service::load(
                        &http,
                        &d,
                        &url_for_load,
                        &title_for_load,
                        &content_type,
                        position,
                        size,
                        duration,
                    )
                    .await
                }
                ("cast", _) => {
                    match registry.connection(&device_id_owned).await {
                        Err(e) => Err(e),
                        Ok(mut conns) => match conns.get_mut(&device_id_owned) {
                            Some(conn) => {
                                cast_control::load(
                                    conn,
                                    &url_for_load,
                                    &title_for_load,
                                    &content_type,
                                    position,
                                    &subtitle_tracks,
                                    selected,
                                )
                                .await
                            }
                            None => Err("could not open a Cast session".to_string()),
                        },
                    }
                }
                (other, _) => Err(format!("device kind {} not supported yet", other)),
            };
            let mut inner = registry.inner.write().await;
            match result {
                Ok(()) => {
                    inner.errors.remove(&format!("play:{}", device_id_owned));
                }
                Err(e) => {
                    tracing::warn!("Cast load failed on {}: {}", device_id_owned, e);
                    inner.errors.insert(format!("play:{}", device_id_owned), e);
                }
            }
        });

        serde_json::json!({
            "ok": true,
            "device": device["name"],
            "url": active.url,
            "kind": kind,
            "base_origin": base_origin,
        })
    }

    pub async fn control(
        self: &Arc<Self>,
        device_id: &str,
        action: &str,
        value: Option<f64>,
    ) -> serde_json::Value {
        let device = match self.resolve_device(device_id).await {
            Some(d) => d,
            None => return err("Unknown device - rescan and try again."),
        };

        if action == "subtitle_offset" {
            let (filename, origin, active_sub_id) = {
                let inner = self.inner.read().await;
                match inner.active.get(device_id) {
                    Some(a) => (a.filename.clone(), a.origin.clone(), a.active_subtitle_id),
                    None => return err("No active playback"),
                }
            };
            let position = self
                .status(device_id)
                .await
                .get("position")
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0);
            return self
                .play(
                    device_id,
                    &filename,
                    Some(position),
                    origin.as_deref(),
                    Some(value.unwrap_or(0.0)),
                    Some(active_sub_id),
                )
                .await;
        }

        let kind = device["kind"].as_str().unwrap_or("dlna").to_string();
        let outcome = if kind == "cast" {
            self.cast_action(device_id, action, value).await
        } else {
            let dlna_device: Option<DlnaDevice> = serde_json::from_value(device.clone()).ok();
            match dlna_device {
                Some(d) => {
                    let http = dlna_service::http_client(Duration::from_secs(8));
                    dlna_service::command(&http, &d, action, value).await
                }
                None => Err(format!("device kind {} not supported yet", kind)),
            }
        };

        if let Err(e) = outcome {
            return err(&e);
        }

        // A stopped Cast has no session worth keeping.
        if action == "stop" {
            self.drop_connection(device_id).await;
        }

        let mut inner = self.inner.write().await;
        if action == "subtitle" {
            if let Some(a) = inner.active.get_mut(device_id) {
                a.active_subtitle_id = value.unwrap_or(0.0) as i64;
            }
        } else if action == "stop" {
            inner.active.remove(device_id);
        }
        serde_json::json!({ "ok": true })
    }

    /// Ground truth for "did the TV actually move?" - read from the device.
    pub async fn status(self: &Arc<Self>, device_id: &str) -> serde_json::Value {
        let device = match self.resolve_device(device_id).await {
            Some(d) => d,
            None => return err("Unknown device - rescan and try again."),
        };

        let kind = device["kind"].as_str().unwrap_or("dlna").to_string();
        let payload = if kind == "cast" {
            // Read from the receiver. A cached read freezes the cast bar and
            // can make a position from minutes ago look like a command that
            // never landed: receivers push MEDIA_STATUS on transitions only.
            // Redials once if the connection has since died.
            match self.cast_status(device_id).await {
                Ok(v) => v,
                Err(e) => return err(&e),
            }
        } else {
            match serde_json::from_value::<DlnaDevice>(device.clone()) {
                Ok(d) => {
                    let http = dlna_service::http_client(Duration::from_secs(8));
                    // Best-effort per field: a renderer that answers transport
                    // info but not position info still reports its state.
                    let s = dlna_service::status(&http, &d).await;
                    serde_json::to_value(s).unwrap_or(serde_json::Value::Null)
                }
                Err(_) => return err(&format!("device kind {} not supported yet", kind)),
            }
        };

        let (active_fields, last_error) = {
            let inner = self.inner.read().await;
            let fields = inner
                .active
                .get(device_id)
                .map(|a| a.public_fields())
                .unwrap_or(serde_json::Value::Null);
            (fields, inner.errors.get(&format!("play:{}", device_id)).cloned())
        };

        let mut out = payload;
        out["ok"] = serde_json::Value::Bool(true);
        out["device"] = device["name"].clone();
        out["kind"] = device["kind"].clone();
        if active_fields.is_object() {
            if let Some(map) = active_fields.as_object() {
                for (k, v) in map {
                    out[k] = v.clone();
                }
            }
        }
        // The load runs detached, so this is how a refusal reaches the remote
        // instead of leaving it stuck on "starting".
        if let Some(e) = last_error {
            out["last_error"] = serde_json::Value::String(e);
        }
        out
    }

    /// The path relative to its media root, which is what `/media/` is keyed
    /// on. Falls back to the bare filename, which the route also resolves.
    fn rel_path(&self, resolved: &Path) -> String {
        for root in self.roots.iter() {
            if let Ok(canon_root) = root.canonicalize() {
                if let Ok(rel) = resolved.strip_prefix(&canon_root) {
                    return rel.to_string_lossy().replace('\\', "/");
                }
            }
        }
        resolved
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default()
    }

    /// HLS playlist for a media path, when a cache already exists.
    ///
    /// The directory key is a hash of path+size+mtime, so it is derived rather
    /// than reconstructed - asking for a playlist that does not exist is the
    /// documented "Chromecast cannot play .mkv directly" case, not an error.
    pub fn hls_playlist(&self, resolved: &Path) -> Option<std::path::PathBuf> {
        let dir = crate::services::hls_service::HlsService::find_hls_dir(
            resolved,
            &self.roots,
            &self.cache_dir,
        );
        let playlist = dir.join("playlist.m3u8");
        playlist.is_file().then_some(playlist)
    }
}

/// One Cast transport verb.
async fn dispatch_cast_action(
    conn: &mut CastConnection,
    action: &str,
    value: Option<f64>,
) -> Result<(), String> {
    match action {
        "play" => cast_control::play(conn).await,
        "pause" => cast_control::pause(conn).await,
        "seek" => cast_control::seek(conn, value.unwrap_or(0.0)).await,
        "volume" => cast_control::set_volume(conn, value.unwrap_or(0.0)).await,
        "mute" => cast_control::set_muted(conn, value.unwrap_or(0.0) != 0.0).await,
        "subtitle" => cast_control::select_subtitle(conn, value.unwrap_or(0.0) as i64).await,
        "stop" => {
            // `stop` must mean "the television is free again", not "playback
            // paused". Stopping playback alone leaves the receiver app running
            // as a blank screen with a cast icon, so the app is quit too - and
            // then we wait for it to actually go, because closing the socket
            // straight after STOP_APP tore the transport down before the
            // receiver could act on it.
            let stopped = cast_control::stop_media(conn).await;
            if let Err(e) = stopped {
                // A receiver with nothing loaded refuses STOP; that is fine,
                // and quitting the app is still the thing that was asked for.
                tracing::debug!("Cast stop media reported: {}", e);
            }
            cast_control::quit_app(conn).await?;
            if cast_control::wait_for_app_gone(conn, Duration::from_secs(5)).await {
                Ok(())
            } else {
                Err(
                    "the receiver did not close its media app, so the television may be left on a blank screen"
                        .to_string(),
                )
            }
        }
        other => Err(format!("unsupported action: {}", other)),
    }
}

fn err(message: &str) -> serde_json::Value {
    serde_json::json!({ "ok": false, "error": message })
}

fn is_video(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()).map(|e| e.to_lowercase()).as_deref(),
        Some("mkv" | "mp4" | "m4v" | "webm" | "mov" | "avi")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_extensions_are_recognised_case_insensitively() {
        assert!(is_video(Path::new("a.MKV")));
        assert!(is_video(Path::new("a.mp4")));
        assert!(is_video(Path::new("/root/sub/a.WEBM")));
        assert!(!is_video(Path::new("a.srt")));
        assert!(!is_video(Path::new("noext")));
    }

    #[test]
    fn active_cast_public_fields_exclude_the_internal_url() {
        let a = ActiveCast {
            filename: "f.mkv".into(),
            origin: None,
            url: "http://192.168.1.9:8000/media/f.mkv".into(),
            title: "f.mkv".into(),
            subtitle_offset: 0.0,
            subtitles: vec![],
            active_subtitle_id: 0,
        };
        let fields = a.public_fields();
        assert!(fields.get("url").is_none(), "the LAN URL is an internal detail");
        assert_eq!(fields["filename"], "f.mkv");
        assert_eq!(fields["title"], "f.mkv");
    }

    #[test]
    fn errors_are_reported_in_the_shape_every_cast_endpoint_uses() {
        assert_eq!(err("boom")["ok"], false);
        assert_eq!(err("boom")["error"], "boom");
    }
}