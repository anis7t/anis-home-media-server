use crate::error::AppError;
use crate::models::job::JobStatus;
use crate::models::transcode::TranscodeStatusResponse;
use crate::services::hls_service::HlsService;
use crate::services::job_service::JobService;
use crate::services::path_resolver::PathResolver;
use crate::services::range_service::RangeService;
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, HeaderMap, Method, Response, StatusCode},
    Json,
};
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::Arc;

/// Media-root-relative key with forward slashes - the same shape as
/// `movies.filename` / Flask's `get_rel_path()`. Job rows are keyed on it so
/// the same title resolves to one row regardless of which root holds it.
///
/// The roots are compared longest-first so a root nested inside another
/// (`E:/MediaServer` inside a configured `E:/`) cannot win and leave a
/// half-stripped key behind.
fn video_path_key(video_path: &PathBuf, roots: &[PathBuf]) -> String {
    let raw = video_path.to_string_lossy().replace('\\', "/");
    let raw_clean = raw.strip_prefix("//?/").unwrap_or(&raw);

    let mut prefixes: Vec<String> = roots
        .iter()
        .map(|r| {
            let s = r.to_string_lossy().replace('\\', "/");
            let s_clean = s.strip_prefix("//?/").unwrap_or(&s).to_string();
            if s_clean.ends_with('/') {
                s_clean
            } else {
                format!("{}/", s_clean)
            }
        })
        .collect();
    prefixes.sort_by_key(|p| std::cmp::Reverse(p.len()));

    for prefix in prefixes {
        if let Some(rest) = raw_clean.strip_prefix(&prefix) {
            return rest.to_string();
        }
    }
    raw_clean.to_string()
}

#[derive(Clone)]
pub struct TranscodeState {
    pub roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
    /// Present from 6A onward. `None` keeps the handler filesystem-only,
    /// which is how the pre-6A behaviour is reproduced for callers that
    /// build a state without a pool.
    pub pool: Option<sqlx::PgPool>,
}

#[derive(Debug, Deserialize)]
pub struct TranscodeQuery {
    pub compat: Option<String>,
}

pub async fn transcode_handler(
    State(state): State<TranscodeState>,
    Query(query): Query<TranscodeQuery>,
    headers: HeaderMap,
    method: Method,
    Path(filename): Path<String>,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        let mut res = Response::new(Body::empty());
        *res.status_mut() = StatusCode::OK;
        let h = res.headers_mut();
        h.insert("access-control-allow-origin", "*".parse().unwrap());
        h.insert("access-control-allow-methods", "GET, HEAD, OPTIONS".parse().unwrap());
        h.insert("access-control-allow-headers", "Range, Origin, Accept, Content-Type".parse().unwrap());
        h.insert("access-control-expose-headers", "Content-Length, Content-Range, Accept-Ranges".parse().unwrap());
        h.insert("cross-origin-resource-policy", "cross-origin".parse().unwrap());
        return Ok(res);
    }

    let video_path = PathResolver::resolve_media_path(&filename, &state.roots)?;
    let mode = if query.compat.as_deref() == Some("1") {
        "compat"
    } else {
        "direct"
    };

    let cached = HlsService::get_transcode_cache_path(&video_path, mode, &state.cache_dir);
    if cached.is_file() {
        let mut res = RangeService::stream_file(cached, headers, method).await?;
        let h = res.headers_mut();
        h.insert(header::CACHE_CONTROL, "public, max-age=3600".parse().unwrap());
        h.insert("access-control-allow-origin", "*".parse().unwrap());
        h.insert("access-control-allow-methods", "GET, HEAD, OPTIONS".parse().unwrap());
        h.insert("access-control-allow-headers", "Range, Origin, Accept, Content-Type".parse().unwrap());
        h.insert("access-control-expose-headers", "Content-Length, Content-Range, Accept-Ranges".parse().unwrap());
        h.insert("cross-origin-resource-policy", "cross-origin".parse().unwrap());
        return Ok(res);
    }

    // Not yet cached: return 503 retry response
    let payload = serde_json::json!({
        "status": "transcoding",
        "message": "Transcoded stream is not yet cached",
        "filename": filename
    });

    let mut res = Response::new(Body::from(payload.to_string()));
    *res.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
    let h = res.headers_mut();
    h.insert(header::CONTENT_TYPE, "application/json".parse().unwrap());
    h.insert(header::RETRY_AFTER, "2".parse().unwrap());
    h.insert(header::CACHE_CONTROL, "no-cache, no-store, must-revalidate".parse().unwrap());
    h.insert("access-control-allow-origin", "*".parse().unwrap());
    return Ok(res);
}

pub async fn transcode_status_handler(
    State(state): State<TranscodeState>,
    Path(filename): Path<String>,
) -> Result<Json<TranscodeStatusResponse>, AppError> {
    let video_path = PathResolver::resolve_media_path(&filename, &state.roots)?;

    // 6A: a live job row is authoritative when one exists. Anything else -
    // including every terminal state, and every title with no row at all -
    // falls through to the filesystem derivation below, so this change
    // cannot alter the response for any title that has no job record.
    if let Some(pool) = state.pool.as_ref() {
        match JobService::get_by_filename(pool, &video_path_key(&video_path, &state.roots), "hls")
            .await
        {
            Ok(Some(job)) => {
                let live = JobStatus::parse(&job.status).map(|s| s.is_live()).unwrap_or(false);
                if live {
                    let status = if job.status == "queued" {
                        "queued".to_string()
                    } else {
                        "transcoding".to_string()
                    };
                    return Ok(Json(TranscodeStatusResponse {
                        status,
                        progress: job.progress,
                        speed: job.speed,
                        fps: job.fps,
                        eta: job.eta,
                        is_complete: false,
                        error: job.error,
                    }));
                }
            }
            // A pool read failure must not take status down: the filesystem
            // derivation is still correct for everything except a job in
            // flight, which is strictly better than a 500.
            Err(_) => {}
            Ok(None) => {}
        }
    }

    let hls_dir = HlsService::find_hls_dir(&video_path, &state.roots, &state.cache_dir);

    // 1. Check if completed HLS playlist exists
    let playlist_file = hls_dir.join("playlist.m3u8");
    if playlist_file.is_file() {
        if let Ok(content) = std::fs::read_to_string(&playlist_file) {
            if content.contains("#EXT-X-ENDLIST") {
                return Ok(Json(TranscodeStatusResponse {
                    status: "complete".to_string(),
                    progress: Some(100.0),
                    speed: None,
                    fps: None,
                    eta: Some(0.0),
                    is_complete: true,
                    error: None,
                }));
            } else if content.contains("segment_") {
                return Ok(Json(TranscodeStatusResponse {
                    status: "transcoding".to_string(),
                    progress: None,
                    speed: None,
                    fps: None,
                    eta: None,
                    is_complete: false,
                    error: None,
                }));
            }
        }
    }

    // 2. Check if direct transcode cache file exists
    let direct_cache = HlsService::get_transcode_cache_path(&video_path, "direct", &state.cache_dir);
    if direct_cache.is_file() {
        return Ok(Json(TranscodeStatusResponse {
            status: "complete".to_string(),
            progress: Some(100.0),
            speed: None,
            fps: None,
            eta: Some(0.0),
            is_complete: true,
            error: None,
        }));
    }

    // 3. Otherwise idle
    Ok(Json(TranscodeStatusResponse {
        status: "idle".to_string(),
        progress: None,
        speed: None,
        fps: None,
        eta: None,
        is_complete: false,
        error: None,
    }))
}

/// `POST /api/transcode/start/{*path}`
///
/// Legacy transcode start compatibility endpoint invoked by the Flutter client.
/// Verifies the video exists across roots, then enqueues background HLS transcoding
/// (or returns ready if direct-play / complete). If nonexistent or non-video, returns 404.
pub async fn transcode_start_handler(
    State(state): State<TranscodeState>,
    Path(path): Path<String>,
) -> Result<Json<serde_json::Value>, AppError> {
    let decoded = crate::routes::jobs::percent_decode(&path);
    if decoded.is_empty() {
        return Err(AppError::BadRequest("Filename is required".to_string()));
    }

    let video_path = PathResolver::resolve_media_path(&decoded, &state.roots)?;
    let ext = video_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    let is_video = matches!(
        ext.as_str(),
        "mp4" | "mkv" | "webm" | "mov" | "avi" | "m4v"
    );
    if !is_video {
        return Err(AppError::NotFound("Not a video file".to_string()));
    }

    let is_direct_play = matches!(ext.as_str(), "mp4" | "m4v" | "webm");
    if is_direct_play {
        return Ok(Json(serde_json::json!({
            "status": "ready",
            "message": "Direct playable media does not require transcoding"
        })));
    }

    let hls_dir = HlsService::find_hls_dir(&video_path, &state.roots, &state.cache_dir);
    let playlist_file = hls_dir.join("playlist.m3u8");
    if playlist_file.is_file() {
        if let Ok(content) = std::fs::read_to_string(&playlist_file) {
            if content.contains("#EXT-X-ENDLIST") {
                return Ok(Json(serde_json::json!({
                    "status": "ready",
                    "message": "Media is already fully transcoded"
                })));
            }
        }
    }

    let rel_key = video_path_key(&video_path, &state.roots);
    if let Some(pool) = state.pool.as_ref() {
        let _ = JobService::enqueue(pool, &rel_key, "hls", false).await?;
    }

    Ok(Json(serde_json::json!({
        "status": "queued",
        "message": "Transcoding started in background"
    })))
}

