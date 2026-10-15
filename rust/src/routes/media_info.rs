use crate::error::AppError;
use crate::services::hls_service::HlsService;
use crate::services::probe_service::{
    cached_probe, cached_source_video_duration, ffmpeg_binary, ffprobe_binary, ProbeResult,
};
use crate::services::path_resolver::PathResolver;
use axum::{
    extract::{Path, State},
    http::{HeaderValue, Method, Response, StatusCode},
};
use serde_json::{json, Value};
use sqlx::PgPool;
use std::path::{Path as FsPath, PathBuf};
use std::sync::Arc;

#[derive(Clone)]
pub struct MediaInfoState {
    pub roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
    pub pool: Option<sqlx::PgPool>,
}

/// Containers the browser can play directly. Anything else is served as HLS.
const DIRECT_PLAY_EXTENSIONS: [&str; 3] = ["mp4", "m4v", "webm"];

/// Video extensions, mirroring Flask's `VIDEO_EXTENSIONS` for the `is_video`
/// gate. `is_video` also requires a non-zero size, so an empty placeholder is
/// a 404 rather than a zero-length "film".
const VIDEO_EXTENSIONS: [&str; 8] = [
    "mp4", "m4v", "webm", "mkv", "avi", "mov", "wmv", "flv",
];

fn extension_of(path: &FsPath) -> String {
    path.extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase()
}

fn needs_transcode(path: &FsPath) -> bool {
    !DIRECT_PLAY_EXTENSIONS.contains(&extension_of(path).as_str())
}

fn is_video(path: &FsPath) -> bool {
    if !VIDEO_EXTENSIONS.contains(&extension_of(path).as_str()) {
        return false;
    }
    std::fs::metadata(path).map(|m| m.is_file() && m.len() > 0).unwrap_or(false)
}

/// Minimum coverage ratio for an in-progress playlist to read as ready.
///
/// Read from the environment so Flask and Rust can be tuned together; Flask
/// uses `getattr(config, 'MIN_COVERAGE_RATIO', 0.98)`.
fn min_coverage_ratio() -> f64 {
    std::env::var("MIN_COVERAGE_RATIO")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.98)
}

/// Is a cache complete? **A predicate. It must never write.**
///
/// `#EXT-X-ENDLIST` is authoritative when present. Otherwise the accumulated
/// `#EXTINF` labels are divided by the *video stream's* end, never the
/// container duration - a WEB-DL container running minutes past the last frame
/// scored a fully rendered cache as incomplete forever.
///
/// This ratio is label arithmetic, and labels are the measure this project has
/// measured to be untrustworthy: a cache read 100% by duration while missing
/// 277.2s of frames across 101 chunks. Frame accounting supersedes it in a
/// later phase; until then this reproduces Flask exactly and writes nothing.
/// A previous revision appended ENDLIST here, which would seal exactly the
/// frame-deficient caches the frame accounting exists to catch.
fn is_hls_ready(playlist: &FsPath, source_duration: f64) -> bool {
    let text = match std::fs::read_to_string(playlist) {
        Ok(t) => t,
        Err(_) => return false,
    };
    if text.contains("#EXT-X-ENDLIST") {
        return true;
    }
    if source_duration <= 0.0 {
        return false;
    }
    let cumulative: f64 = text
        .lines()
        .filter_map(|l| l.strip_prefix("#EXTINF:"))
        .filter_map(|l| l.split(',').next())
        .filter_map(|v| v.trim().parse::<f64>().ok())
        .sum();
    cumulative / source_duration >= min_coverage_ratio()
}

/// `GET /api/media-info/{*filename}` - technical details and capability report.
pub async fn media_info_handler(
    State(state): State<MediaInfoState>,
    Path(filename): Path<String>,
    method: Method,
) -> Result<Response<axum::body::Body>, AppError> {
    if method == Method::OPTIONS {
        let mut res = Response::new(axum::body::Body::empty());
        *res.status_mut() = StatusCode::OK;
        let h = res.headers_mut();
        h.insert("access-control-allow-origin", HeaderValue::from_static("*"));
        h.insert(
            "access-control-allow-methods",
            HeaderValue::from_static("GET, HEAD, OPTIONS"),
        );
        return Ok(res);
    }

    let payload = build_media_info(&state, &filename).await?;

    let json = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
    let body = if method == Method::HEAD {
        axum::body::Body::empty()
    } else {
        axum::body::Body::from(json)
    };
    let mut res = Response::new(body);
    let h = res.headers_mut();
    h.insert(
        axum::http::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    h.insert("access-control-allow-origin", HeaderValue::from_static("*"));
    Ok(res)
}

async fn build_media_info(
    state: &MediaInfoState,
    filename: &str,
) -> Result<Value, AppError> {
    let path = PathResolver::resolve_media_path(filename, &state.roots)?;
    if !is_video(&path) {
        return Err(AppError::NotFound(format!("'{}' is not a video", filename)));
    }

    let probe: ProbeResult = cached_probe(&path).await;
    let container_duration = probe.container_duration();
    let direct_play = !needs_transcode(&path);

    // HLS timelines are built from our own playlist, so they advertise the
    // video stream's end; a container running past the last frame would show
    // a seek tail that can never play. Direct play keeps the container value
    // because there the browser reads the file's own metadata.
    let duration = if direct_play {
        container_duration
    } else {
        let video_end = cached_source_video_duration(&path).await;
        if video_end > 0.0 {
            video_end
        } else {
            container_duration
        }
    };

    let needs_tc = needs_transcode(&path);
    let is_ready = if needs_tc {
        let hls_dir = HlsService::find_hls_dir(&path, &state.roots, &state.cache_dir);
        let source_duration = cached_source_video_duration(&path).await;
        is_hls_ready(&hls_dir.join("playlist.m3u8"), source_duration)
    } else {
        true
    };

    let meta = movie_metadata(state, filename).await;
    let video = probe.first_stream("video");
    let probe_available = ffprobe_binary().is_some();

    let reason = if !probe_available {
        "Codec inspection unavailable: install ffprobe for a precise compatibility report."
    } else {
        "Direct play is preferred; codec inspection can be extended without changing media files."
    };

    Ok(json!({
        "container": extension_of(&path),
        "duration": duration,
        "video_codec": video.and_then(|v| v.codec_name.clone()).unwrap_or_default(),
        "width": video.and_then(|v| v.width),
        "height": video.and_then(|v| v.height),
        "direct_play": direct_play,
        "needs_transcode": needs_tc,
        "is_transcode_ready": is_ready,
        "ffprobe_available": probe_available,
        "transcoding_available": ffmpeg_binary().is_some(),
        "title": meta.get("title").cloned().unwrap_or(Value::Null),
        "year": meta.get("year").cloned().unwrap_or(Value::Null),
        "overview": meta.get("overview").cloned().unwrap_or(Value::Null),
        "genres": meta.get("genres").cloned().unwrap_or(Value::Null),
        "rating": meta.get("vote_average").cloned().unwrap_or(Value::Null),
        "runtime": meta.get("runtime").cloned().unwrap_or(Value::Null),
        "reason": reason,
    }))
}

/// Movie row for `filename`, falling back to a basename match.
///
/// The fuzzy fallback is reproduced deliberately: Flask has used it for a
/// long time and clients depend on it resolving. It is also a real hazard -
/// a `LIKE '%name%'` across the whole table can bind one film's metadata to
/// another - which is the same bare-vs-subdirectory filename confusion seen
/// during the catalog reconciliation. Removing it is a deliberate follow-up,
/// not something to smuggle into a parity port.
async fn movie_metadata(state: &MediaInfoState, filename: &str) -> serde_json::Map<String, Value> {
    let pool = match state.pool.as_ref() {
        Some(p) => p,
        None => return serde_json::Map::new(),
    };

    let sql = "SELECT title, year, overview, genres, vote_average, runtime \
               FROM movies WHERE filename = $1 LIMIT 1";
    let mut meta: Option<(Option<String>, Option<i32>, Option<String>, Option<Value>, Option<f64>, Option<i32>)> =
        sqlx::query_as(sql)
            .bind(filename)
            .fetch_optional(pool)
            .await
            .ok()
            .flatten();

    if meta.is_none() {
        let base = FsPath::new(filename)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(filename);
        meta = sqlx::query_as(sql)
            .bind(format!("%{}%", base))
            .fetch_optional(pool)
            .await
            .ok()
            .flatten();
    }

    let (title, year, overview, genres, rating, runtime) = match meta {
        Some(m) => m,
        None => return serde_json::Map::new(),
    };

    let mut map = serde_json::Map::new();
    map.insert("title".into(), title.map(Value::from).unwrap_or(Value::Null));
    map.insert("year".into(), year.map(Value::from).unwrap_or(Value::Null));
    map.insert("overview".into(), overview.map(Value::from).unwrap_or(Value::Null));
    map.insert("genres".into(), genres.unwrap_or(Value::Null));
    map.insert("vote_average".into(), rating.map(Value::from).unwrap_or(Value::Null));
    map.insert("runtime".into(), runtime.map(Value::from).unwrap_or(Value::Null));
    map
}

/// Keep the pool type referenced even when the field is unused in tests.
#[allow(dead_code)]
fn _pool_type_is_used(_p: &PgPool) {}