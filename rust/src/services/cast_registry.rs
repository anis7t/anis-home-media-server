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

use crate::services::cast_origin::{build_media_url, resolve_origin};
use crate::services::dlna_service::{self, DlnaDevice};
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::RwLock;

/// What the client asked to play, remembered so `status` can describe it and
/// so a subtitle-offset change can re-issue the same load.
#[derive(Debug, Clone)]
pub struct ActiveCast {
    pub filename: String,
    pub origin: Option<String>,
    pub url: String,
    pub title: String,
    pub subtitle_offset: f64,
    pub subtitles: Vec<SubtitleTrack>,
    pub active_subtitle_id: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct SubtitleTrack {
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
            "subtitles": self.subtitles,
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
        })
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

        let mut inner = self.inner.write().await;
        // Replace, not merge: a device that stopped answering is gone.
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

        let active = ActiveCast {
            filename: filename.to_string(),
            origin: origin.map(|s| s.to_string()),
            url: build_media_url(&self.rel_path(&path), origin_url.as_deref(), false),
            title: title.clone(),
            subtitle_offset: subtitle_offset.unwrap_or(0.0),
            subtitles: Vec::new(),
            active_subtitle_id: active_subtitle_id.unwrap_or(0),
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
            let http = dlna_service::http_client(Duration::from_secs(8));
            let result = match dlna_device {
                Some(d) => {
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
                None => Err(format!("device kind {} not supported yet", kind_for_load)),
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

        let dlna_device: Option<DlnaDevice> = serde_json::from_value(device.clone()).ok();
        let outcome = match dlna_device {
            Some(d) => {
                let http = dlna_service::http_client(Duration::from_secs(8));
                dlna_service::command(&http, &d, action, value).await
            }
            None => Err(format!(
                "device kind {} not supported yet",
                device["kind"].as_str().unwrap_or("?")
            )),
        };

        if let Err(e) = outcome {
            return err(&e);
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

        let payload = match serde_json::from_value::<DlnaDevice>(device.clone()) {
            Ok(d) => {
                let http = dlna_service::http_client(Duration::from_secs(8));
                // Best-effort per field: a renderer that answers transport
                // info but not position info still reports its state.
                let s = dlna_service::status(&http, &d).await;
                serde_json::to_value(s).unwrap_or(serde_json::Value::Null)
            }
            Err(_) => {
                let kind = device["kind"].as_str().unwrap_or("?").to_string();
                return err(&format!("device kind {} not supported yet", kind));
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