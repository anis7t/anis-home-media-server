use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProbeStream {
    pub codec_type: Option<String>,
    pub codec_name: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    #[serde(default)]
    pub pix_fmt: Option<String>,
    #[serde(default)]
    pub r_frame_rate: Option<String>,
    #[serde(default)]
    pub duration: Option<String>,
    #[serde(rename = "duration_ts", default)]
    pub duration_ts: Option<i64>,
    #[serde(default)]
    pub tags: HashMap<String, String>,
    #[serde(default)]
    pub bit_rate: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProbeFormat {
    pub duration: Option<String>,
    #[serde(default)]
    pub bit_rate: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProbeResult {
    #[serde(default)]
    pub streams: Vec<ProbeStream>,
    #[serde(default)]
    pub format: ProbeFormat,
}

impl ProbeResult {
    pub fn container_duration(&self) -> f64 {
        self.format
            .duration
            .as_deref()
            .and_then(|d| d.parse::<f64>().ok())
            .unwrap_or(0.0)
    }

    pub fn container_bitrate(&self) -> u64 {
        self.format
            .bit_rate
            .as_deref()
            .and_then(|b| b.parse::<u64>().ok())
            .unwrap_or(0)
    }

    /// First stream of a given type. `ffprobe` orders streams by index, so
    /// the first video stream is the display video, matching Flask's
    /// `next((s for s in ... if codec_type == 'video'), {})`.
    pub fn first_stream(&self, kind: &str) -> Option<&ProbeStream> {
        self.streams
            .iter()
            .find(|s| s.codec_type.as_deref() == Some(kind))
    }
}

pub struct ProbeService;

impl ProbeService {
    /// Run `ffprobe` once and parse the JSON.
    ///
    /// Returns an empty result when ffprobe is unavailable or fails, which
    /// is Flask's `probe_media` behaviour (`return {}`). Callers depend on
    /// that: a missing probe must yield `duration: 0` and the
    /// `ffprobe_available: false` report, not a 500.
    pub async fn probe(path: &Path) -> ProbeResult {
        let probe = match ffprobe_binary() {
            Some(p) => p,
            None => return ProbeResult::default(),
        };

        let output = tokio::process::Command::new(probe)
            .arg("-v")
            .arg("error")
            .arg("-show_streams")
            .arg("-show_format")
            .arg("-of")
            .arg("json")
            .arg(path)
            .output()
            .await;

        let output = match output {
            Ok(o) => o,
            Err(e) => {
                tracing::warn!("ffprobe failed to run for {}: {}", path.display(), e);
                return ProbeResult::default();
            }
        };

        serde_json::from_slice(&output.stdout).unwrap_or_default()
    }

    /// End time of the *video* stream, in seconds - the only safe
    /// denominator for coverage and chunk planning.
    ///
    /// Container duration is deliberately NOT safe: WEB-DL/WEBRip muxes carry
    /// audio and subtitle packets minutes past the last video frame (a 9839s
    /// container whose picture ends at 8254.6s), which pegs a finished cache
    /// below 100% forever and re-renders it.
    ///
    /// Falls back to the container duration when the video end cannot be
    /// measured, so callers degrade rather than fail. That fallback is
    /// *internal on purpose*: Flask calls this with an explicit fallback
    /// argument at two sites, but a non-`None` fallback disables this
    /// function's own probing in the Python original - returning a hard 0,
    /// which makes `plan_chunks(0)` empty and the cache judged vacuously
    /// complete. Same behaviour, without the trap.
    pub async fn source_video_duration(path: &Path) -> f64 {
        let probe = Self::probe(path).await;
        let container = probe.container_duration();

        // 1. Stream-level duration, then the Matroska DURATION tag.
        if let Some(v) = probe.first_stream("video") {
            let end = video_stream_end(v);
            if end > 0.0 {
                return end;
            }
        }

        // 2. Neither signal exists for every muxer. Fall back to measuring the
        //    real end of the video by scanning packets, which is what Flask
        //    does and what makes the difference between the picture's end and
        //    the container's. A library MKV measured 4.25s of trailing audio
        //    this way - reporting the container there would overstate the
        //    denominator and can score a finished cache as incomplete.
        let scanned = Self::video_end_by_packet_scan(path, container).await;
        if scanned > 0.0 {
            return scanned;
        }

        container
    }

    /// End of the last video packet, measured by ffprobe.
    ///
    /// Jumps to the container midpoint via the index and reads forward
    /// (`-read_intervals <mid>%+99999`), which is ~0.3s on a multi-GB MKV
    /// instead of the ~9s a full packet scan costs. Only if that yields
    /// nothing does it scan the whole file.
    pub async fn video_end_by_packet_scan(path: &Path, container_duration: f64) -> f64 {
        if let Some(end) = Self::scan_packets(path, container_duration).await {
            return end;
        }
        Self::scan_packets(path, 0.0).await.unwrap_or(0.0)
    }

    async fn scan_packets(path: &Path, seek_pct: f64) -> Option<f64> {
        let probe = ffprobe_binary()?;
        let mut cmd = tokio::process::Command::new(probe);
        cmd.arg("-v").arg("error").arg("-select_streams").arg("v:0");
        if seek_pct > 0.0 {
            cmd.arg("-read_intervals")
                .arg(format!("{:.3}%+99999", seek_pct));
        }
        cmd.arg("-show_entries")
            .arg("packet=pts_time,duration_time")
            .arg("-of")
            .arg("csv=p=0")
            .arg(path);

        let out = tokio::time::timeout(std::time::Duration::from_secs(15), cmd.output())
            .await
            .ok()?
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&out.stdout);

        let mut last_end: Option<f64> = None;
        for line in text.lines() {
            let mut parts = line.trim().split(',');
            let pts = match parts.next().and_then(|p| p.parse::<f64>().ok()) {
                Some(p) => p,
                None => continue,
            };
            let dur = parts
                .next()
                .and_then(|d| d.parse::<f64>().ok())
                .unwrap_or(0.0);
            last_end = Some(pts + dur);
        }
        last_end.filter(|v| *v > 0.0)
    }
}

/// Seconds covered by one video stream.
///
/// Matroska track tags are locale-suffixed (`DURATION-eng`), so a lookup of
/// the bare `DURATION` key misses them - that bug once made
/// `source_video_duration` silently fall through to the container duration.
/// Any key starting with `DURATION` is accepted for that reason.
fn video_stream_end(v: &ProbeStream) -> f64 {
    if let Some(d) = v.duration.as_deref() {
        if let Ok(parsed) = d.parse::<f64>() {
            if parsed > 0.0 {
                return parsed;
            }
        }
    }
    if let Some(ts) = v.duration_ts {
        if ts > 0 {
            return ts as f64 / 1_000_000.0;
        }
    }
    for (k, val) in &v.tags {
        if k.eq_ignore_ascii_case("DURATION") || k.to_ascii_uppercase().starts_with("DURATION") {
            if let Some(parsed) = parse_duration_value(val) {
                if parsed > 0.0 {
                    return parsed;
                }
            }
        }
    }
    0.0
}

/// Parse a duration that may be either plain seconds (`"8254.6"`) or a
/// Matroska timestamp (`"01:40:06.042000000"`).
///
/// The timestamp form is what Matroska actually emits in its `DURATION` track
/// tags, and it is very often the *only* video-end signal there is: measured on
/// a library MKV, `stream.duration` and `duration_ts` were both absent and the
/// tag was the sole source. Parsing it as a float fails silently, which drops
/// the answer to the container duration - the exact denominator error this
/// function exists to avoid.
fn parse_duration_value(raw: &str) -> Option<f64> {
    let v = raw.trim();
    if v.is_empty() {
        return None;
    }
    if let Ok(f) = v.parse::<f64>() {
        return Some(f);
    }
    if !v.contains(':') {
        return None;
    }
    let mut total = 0.0f64;
    for part in v.split(':') {
        total = total * 60.0 + part.trim().parse::<f64>().ok()?;
    }
    Some(total)
}

/// Memoized `source_video_duration`, keyed by path + size + mtime so an
/// edited or replaced file is re-measured rather than served a stale answer.
fn duration_cache() -> &'static Mutex<HashMap<(String, u64, i128), f64>> {
    static CACHE: std::sync::OnceLock<Mutex<HashMap<(String, u64, i128), f64>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn cache_key(path: &Path) -> Option<(String, u64, i128)> {
    let md = std::fs::metadata(path).ok()?;
    let mtime = md
        .modified()
        .ok()
        .and_then(|m| m.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as i128)
        .unwrap_or(0);
    Some((path.to_string_lossy().to_string(), md.len(), mtime))
}

/// Cached variant used on request paths.
///
/// Flask pays for this three times per uncached request - `probe_media()` is
/// not memoized - and a cold MKV `/api/media-info` measured 1.79s against a
/// 0.12s warm repeat. One memoized probe per file keeps the first call and
/// makes the repeat free.
pub async fn cached_source_video_duration(path: &Path) -> f64 {
    let key = match cache_key(path) {
        Some(k) => k,
        None => return ProbeService::source_video_duration(path).await,
    };
    if let Ok(map) = duration_cache().lock() {
        if let Some(v) = map.get(&key) {
            return *v;
        }
    }
    let measured = ProbeService::source_video_duration(path).await;
    if let Ok(mut map) = duration_cache().lock() {
        map.insert(key, measured);
    }
    measured
}

/// Memoized full probe, so one request that needs both the container
/// duration and the video end runs ffprobe once rather than twice.
pub async fn cached_probe(path: &Path) -> ProbeResult {
    static PROBES: std::sync::OnceLock<
        Mutex<HashMap<(String, u64, i128), std::sync::Arc<ProbeResult>>>,
    > = std::sync::OnceLock::new();
    let cache = PROBES.get_or_init(|| Mutex::new(HashMap::new()));

    let key = match cache_key(path) {
        Some(k) => k,
        None => return ProbeService::probe(path).await,
    };
    if let Ok(map) = cache.lock() {
        if let Some(v) = map.get(&key) {
            return (**v).clone();
        }
    }
    let result = std::sync::Arc::new(ProbeService::probe(path).await);
    if let Ok(mut map) = cache.lock() {
        map.insert(key, result.clone());
    }
    (*result).clone()
}

/// `ffprobe` on PATH, if present.
pub fn ffprobe_binary() -> Option<PathBuf> {
    which("ffprobe")
}

/// `ffmpeg` on PATH, if present. Reported by `/api/media-info` so a client
/// can tell "cannot transcode" from "does not need to".
pub fn ffmpeg_binary() -> Option<PathBuf> {
    which("ffmpeg")
}

fn which(bin: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    let exts: Vec<String> = std::env::var("PATHEXT")
        .unwrap_or_else(|_| ".EXE;.CMD;.BAT;.COM".to_string())
        .split(';')
        .map(|e| e.to_ascii_lowercase())
        .collect();
    let exts = if cfg!(windows) {
        exts
    } else {
        vec![String::new()]
    };

    for dir in std::env::split_paths(&path_var) {
        for ext in &exts {
            let candidate = dir.join(format!("{}{}", bin, ext));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_end_prefers_stream_duration() {
        let s = ProbeStream {
            duration: Some("8254.6".into()),
            duration_ts: Some(8_254_600_000),
            ..Default::default()
        };
        assert_eq!(video_stream_end(&s), 8254.6);
    }

    #[test]
    fn video_end_falls_back_to_duration_ts() {
        let s = ProbeStream {
            duration: None,
            duration_ts: Some(8_254_600_000),
            ..Default::default()
        };
        assert!((video_stream_end(&s) - 8254.6).abs() < 0.001);
    }

    #[test]
    fn video_end_accepts_locale_suffixed_matroska_tag() {
        // `DURATION-eng` is what Matroska actually emits; a bare `DURATION`
        // lookup misses it and silently falls back to container duration.
        let mut tags = HashMap::new();
        tags.insert("DURATION-eng".to_string(), "1234.5".to_string());
        let s = ProbeStream {
            tags,
            ..Default::default()
        };
        assert_eq!(video_stream_end(&s), 1234.5);
    }

    #[test]
    fn duration_value_parses_plain_seconds() {
        assert_eq!(parse_duration_value("8254.6"), Some(8254.6));
    }

    #[test]
    fn duration_value_parses_matroska_timestamp() {
        // The form Matroska actually writes, and frequently the only signal.
        assert!((parse_duration_value("01:40:06.042000000").unwrap() - 6006.042).abs() < 1e-6);
        assert_eq!(parse_duration_value("00:00:00.5"), Some(0.5));
        assert_eq!(parse_duration_value(""), None);
        assert_eq!(parse_duration_value("not-a-duration"), None);
    }

    #[test]
    fn video_end_is_zero_when_nothing_measurable() {
        assert_eq!(video_stream_end(&ProbeStream::default()), 0.0);
    }

    #[test]
    fn container_duration_parses_and_defaults_to_zero() {
        let p = ProbeResult {
            format: ProbeFormat {
                duration: Some("8931.59".into()),
                bit_rate: Some("4500000".into()),
                ..Default::default()
            },
            ..Default::default()
        };
        assert!((p.container_duration() - 8931.59).abs() < 0.01);
        assert_eq!(p.container_bitrate(), 4_500_000);
        assert_eq!(ProbeResult::default().container_duration(), 0.0);
        assert_eq!(ProbeResult::default().container_bitrate(), 0);
    }
}
