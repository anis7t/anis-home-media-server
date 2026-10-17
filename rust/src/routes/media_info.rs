use crate::error::AppError;
use crate::models::transcode::QualityOption;
use crate::services::hls_service::HlsService;
use crate::services::probe_service::{
    cached_probe, cached_source_video_duration, ffmpeg_binary, ffprobe_binary, ProbeResult,
};
use crate::services::path_resolver::PathResolver;
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, Method, Response, StatusCode},
};
use serde::Deserialize;
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

#[derive(Debug, Deserialize, Default)]
pub struct MediaInfoQuery {
    pub client: Option<String>,
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

pub fn is_android_client(query_client: Option<&str>, headers: &HeaderMap) -> bool {
    if let Some(c) = query_client {
        let c_lower = c.to_ascii_lowercase();
        if c_lower.contains("android") || c_lower.contains("firetv") {
            return true;
        }
    }
    if let Some(p) = headers.get("x-client-platform").and_then(|v| v.to_str().ok()) {
        let p_lower = p.to_ascii_lowercase();
        if p_lower.contains("android") || p_lower.contains("firetv") {
            return true;
        }
    }
    if let Some(ua) = headers.get(axum::http::header::USER_AGENT).and_then(|v| v.to_str().ok()) {
        let ua_lower = ua.to_ascii_lowercase();
        if ua_lower.contains("android") || ua_lower.contains("aft") || ua_lower.contains("firetv") {
            return true;
        }
    }
    false
}

pub fn evaluate_direct_play(
    container: &str,
    video_codec: Option<&str>,
    audio_codec: Option<&str>,
    is_android: bool,
) -> bool {
    if DIRECT_PLAY_EXTENSIONS.contains(&container) {
        return true;
    }
    if is_android && container == "mkv" {
        let v_ok = matches!(
            video_codec.unwrap_or(""),
            "h264" | "hevc" | "h265" | "vp9" | "av1"
        );
        let a_ok = matches!(
            audio_codec.unwrap_or(""),
            "aac" | "ac3" | "eac3" | "mp3" | "opus" | "flac" | ""
        );
        return v_ok && a_ok;
    }
    false
}

fn build_quality_ladder(
    source_w: u32,
    source_h: u32,
    source_bitrate: u64,
    video_path: &FsPath,
    roots: &[PathBuf],
    cache_dir: &FsPath,
    filename: &str,
) -> Vec<QualityOption> {
    let mut ladder = Vec::new();

    // 1. Prepend Direct Play (Source)
    ladder.push(QualityOption {
        label: "Direct Play (Source)".to_string(),
        quality: "source".to_string(),
        height: source_h,
        width: source_w,
        bitrate: source_bitrate,
        is_direct: true,
        is_ready: true,
        hls_url: None,
    });

    if source_h == 0 || source_w == 0 {
        return ladder;
    }

    // 2. Iterate standard qualities, strictly filtering out any tier where tier_height > source_h
    for &(label, _, tier_h, bitrate, _) in HlsService::STANDARD_QUALITIES {
        if tier_h > source_h {
            continue;
        }

        // Calculate aspect-ratio scaled width, guaranteed even (divisible by 2)
        // w = (round((source_w * tier_h) / source_h)) & !1
        let scaled_w = ((source_w as u64 * tier_h as u64 + (source_h as u64 / 2)) / source_h as u64) as u32;
        let even_w = scaled_w & !1;

        let q_dir = HlsService::find_hls_quality_dir(video_path, roots, cache_dir, Some(label));
        let q_pl = q_dir.join("playlist.m3u8");
        let is_ready = if q_pl.is_file() {
            if let Ok(c) = std::fs::read_to_string(&q_pl) {
                c.contains("segment_") || c.contains("#EXT-X-ENDLIST")
            } else {
                false
            }
        } else {
            false
        };

        let hls_url = Some(format!("/hls/{}/{}/playlist.m3u8", filename, label));

        ladder.push(QualityOption {
            label: label.to_string(),
            quality: label.to_string(),
            height: tier_h,
            width: even_w,
            bitrate,
            is_direct: false,
            is_ready,
            hls_url,
        });
    }

    ladder
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
    Query(query): Query<MediaInfoQuery>,
    headers: HeaderMap,
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

    let is_android = is_android_client(query.client.as_deref(), &headers);
    let payload = build_media_info(&state, &filename, is_android).await?;

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
    is_android: bool,
) -> Result<Value, AppError> {
    let path = PathResolver::resolve_media_path(filename, &state.roots)?;
    if !is_video(&path) {
        return Err(AppError::NotFound(format!("'{}' is not a video", filename)));
    }

    let probe: ProbeResult = cached_probe(&path).await;
    let container_duration = probe.container_duration();

    let video = probe.first_stream("video");
    let audio = probe.first_stream("audio");
    let v_codec = video.and_then(|v| v.codec_name.as_deref());
    let a_codec = audio.and_then(|a| a.codec_name.as_deref());

    let container = extension_of(&path);
    let direct_play = evaluate_direct_play(&container, v_codec, a_codec, is_android);
    let needs_tc = !direct_play;

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

    let is_ready = if needs_tc {
        let hls_dir = HlsService::find_hls_dir(&path, &state.roots, &state.cache_dir);
        if HlsService::is_hls_complete(&hls_dir) {
            true
        } else {
            let source_duration = cached_source_video_duration(&path).await;
            is_hls_ready(&hls_dir.join("playlist.m3u8"), source_duration)
        }
    } else {
        true
    };

    let meta = movie_metadata(state, filename).await;
    let probe_available = ffprobe_binary().is_some();

    let reason = if !probe_available {
        "Codec inspection unavailable: install ffprobe for a precise compatibility report."
    } else {
        "Direct play is preferred; codec inspection can be extended without changing media files."
    };

    let source_w = video.and_then(|v| v.width).unwrap_or(0) as u32;
    let source_h = video.and_then(|v| v.height).unwrap_or(0) as u32;

    let file_size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    let mut estimated_bitrate = probe.container_bitrate();
    if estimated_bitrate == 0 && duration > 0.0 && file_size > 0 {
        estimated_bitrate = ((file_size as f64 * 8.0) / duration) as u64;
    }

    let quality_ladder = build_quality_ladder(
        source_w,
        source_h,
        estimated_bitrate,
        &path,
        &state.roots,
        &state.cache_dir,
        filename,
    );

    Ok(json!({
        "container": container,
        "duration": duration,
        "video_codec": v_codec.unwrap_or_default(),
        "width": video.and_then(|v| v.width),
        "height": video.and_then(|v| v.height),
        "direct_play": direct_play,
        "needs_transcode": needs_tc,
        "is_transcode_ready": is_ready,
        "ffprobe_available": probe_available,
        "transcoding_available": ffmpeg_binary().is_some(),
        "quality_ladder": quality_ladder,
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

    // `vote_average` is a PostgreSQL `real` (float4). Decoding it straight into
    // an f64 makes the whole row fail to decode, and because the failure was
    // swallowed it silently produced an all-null metadata block - every title
    // reported no title, genres, rating or runtime. f32 is used here, which is
    // the same defensive pattern `progress_service` applies to its floats.
    type MovieMeta = (
        Option<String>,
        Option<i32>,
        Option<String>,
        Option<String>,
        Option<f32>,
        Option<i32>,
    );

    async fn fetch_meta(pool: &PgPool, key: &str) -> Option<MovieMeta> {
        let sql = "SELECT title, year, overview, genres, vote_average, runtime \
                   FROM movies WHERE filename = $1 LIMIT 1";
        sqlx::query_as::<_, MovieMeta>(sql)
            .bind(key)
            .fetch_optional(pool)
            .await
            .ok()
            .flatten()
    }

    let mut meta = fetch_meta(pool, filename).await;

    if meta.is_none() {
        let base = FsPath::new(filename)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(filename);
        meta = fetch_meta(pool, &format!("%{}%", base)).await;
    }

    let (title, year, overview, genres, rating, runtime) = match meta {
        Some(m) => m,
        None => return serde_json::Map::new(),
    };

    let mut map = serde_json::Map::new();
    map.insert("title".into(), title.map(Value::from).unwrap_or(Value::Null));
    map.insert("year".into(), year.map(Value::from).unwrap_or(Value::Null));
    map.insert("overview".into(), overview.map(Value::from).unwrap_or(Value::Null));
    map.insert("genres".into(), genres.map(Value::from).unwrap_or(Value::Null));
    map.insert(
        "vote_average".into(),
        rating.map(|v| Value::from(v as f64)).unwrap_or(Value::Null),
    );
    map.insert("runtime".into(), runtime.map(Value::from).unwrap_or(Value::Null));
    map
}