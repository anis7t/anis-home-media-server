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
pub fn video_path_key(video_path: &std::path::Path, roots: &[PathBuf]) -> String {
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

#[derive(Debug, Deserialize, Default)]
pub struct TranscodeStatusQuery {
    pub quality: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct TranscodeStartQuery {
    pub quality: Option<String>,
}

pub async fn transcode_status_handler(
    State(state): State<TranscodeState>,
    Query(query): Query<TranscodeStatusQuery>,
    Path(filename): Path<String>,
) -> Result<Json<TranscodeStatusResponse>, AppError> {
    let video_path = PathResolver::resolve_media_path(&filename, &state.roots)?;
    let q_norm = query.quality.as_deref().filter(|q| !q.is_empty() && *q != "default");

    // 6A: a live job row is authoritative when one exists.
    if let Some(pool) = state.pool.as_ref() {
        let rel_key = video_path_key(&video_path, &state.roots);
        let job_opt = if let Some(q) = q_norm {
            match JobService::get_by_filename(pool, &rel_key, &format!("hls:{}", q)).await {
                Ok(Some(j)) => Some(j),
                _ => JobService::get_by_filename(pool, &rel_key, "hls").await.ok().flatten(),
            }
        } else {
            JobService::get_by_filename(pool, &rel_key, "hls").await.ok().flatten()
        };

        if let Some(job) = job_opt {
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
                    percent: job.progress,
                    speed: job.speed,
                    fps: job.fps,
                    eta: job.eta,
                    remaining: job.eta,
                    is_complete: false,
                    error: job.error,
                    ..Default::default()
                }));
            }
        }
    }

    let hls_dir = HlsService::find_hls_quality_dir(&video_path, &state.roots, &state.cache_dir, q_norm);

    // 1. Check if completed HLS playlist exists in target directory
    let playlist_file = hls_dir.join("playlist.m3u8");
    if playlist_file.is_file() {
        if let Ok(content) = std::fs::read_to_string(&playlist_file) {
            if content.contains("#EXT-X-ENDLIST") {
                return Ok(Json(TranscodeStatusResponse {
                    status: "complete".to_string(),
                    progress: Some(100.0),
                    percent: Some(100.0),
                    eta: Some(0.0),
                    remaining: Some(0.0),
                    is_complete: true,
                    ..Default::default()
                }));
            } else if content.contains("segment_") {
                return Ok(Json(TranscodeStatusResponse {
                    status: "transcoding".to_string(),
                    is_complete: false,
                    ..Default::default()
                }));
            }
        }
    }

    // If no quality specified, also check aggregate completion across tiers via is_hls_complete
    if q_norm.is_none() {
        let base_dir = HlsService::find_hls_dir(&video_path, &state.roots, &state.cache_dir);
        if HlsService::is_hls_complete(&base_dir) {
            return Ok(Json(TranscodeStatusResponse {
                status: "complete".to_string(),
                progress: Some(100.0),
                percent: Some(100.0),
                eta: Some(0.0),
                remaining: Some(0.0),
                is_complete: true,
                ..Default::default()
            }));
        }

        // 2. Check if direct transcode cache file exists
        let direct_cache = HlsService::get_transcode_cache_path(&video_path, "direct", &state.cache_dir);
        if direct_cache.is_file() {
            return Ok(Json(TranscodeStatusResponse {
                status: "complete".to_string(),
                progress: Some(100.0),
                percent: Some(100.0),
                eta: Some(0.0),
                remaining: Some(0.0),
                is_complete: true,
                ..Default::default()
            }));
        }
    }

    // 3. Otherwise idle
    Ok(Json(TranscodeStatusResponse {
        status: "idle".to_string(),
        is_complete: false,
        ..Default::default()
    }))
}

/// `POST /api/transcode/start/{*path}`
///
/// Transcode start endpoint invoked by clients. Supports optional quality targeting
/// (e.g. `?quality=720p` or JSON `{"quality":"720p"}`).
/// Verifies the video exists across roots, then enqueues background HLS transcoding
/// (or returns ready if direct-play / complete). If nonexistent or non-video, returns 404.
pub async fn transcode_start_handler(
    State(state): State<TranscodeState>,
    Query(query): Query<TranscodeStartQuery>,
    Path(path): Path<String>,
    body: axum::body::Bytes,
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

    let body_quality = if !body.is_empty() {
        serde_json::from_slice::<serde_json::Value>(&body)
            .ok()
            .and_then(|v| v.get("quality").and_then(|q| q.as_str().map(|s| s.to_string())))
    } else {
        None
    };
    let quality = query.quality.or(body_quality);
    let q_norm = quality.as_deref().filter(|q| !q.is_empty() && *q != "source" && *q != "default");

    if let Some(q) = q_norm {
        let q_dir = HlsService::find_hls_quality_dir(&video_path, &state.roots, &state.cache_dir, Some(q));
        let playlist_file = q_dir.join("playlist.m3u8");
        if playlist_file.is_file() {
            if let Ok(content) = std::fs::read_to_string(&playlist_file) {
                if content.contains("#EXT-X-ENDLIST") {
                    return Ok(Json(serde_json::json!({
                        "status": "ready",
                        "message": "Media is already fully transcoded for requested quality"
                    })));
                }
            }
        }

        let rel_key = video_path_key(&video_path, &state.roots);
        let mode = format!("hls:{}", q);
        if let Some(pool) = state.pool.as_ref() {
            let _ = JobService::enqueue_with_priority(
                pool,
                &rel_key,
                &mode,
                true,
                crate::services::job_service::PRIORITY_INTERACTIVE,
            )
            .await?;
        }

        return Ok(Json(serde_json::json!({
            "status": "queued",
            "message": format!("Transcoding started in background for quality {}", q),
            "quality": q
        })));
    }

    // Default (no specific quality requested)
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
    if HlsService::is_hls_complete(&hls_dir) {
        return Ok(Json(serde_json::json!({
            "status": "ready",
            "message": "Media is already fully transcoded"
        })));
    }

    let rel_key = video_path_key(&video_path, &state.roots);
    if let Some(pool) = state.pool.as_ref() {
        let _ = JobService::enqueue_with_priority(
            pool,
            &rel_key,
            "hls",
            true,
            crate::services::job_service::PRIORITY_INTERACTIVE,
        )
        .await?;
    }

    Ok(Json(serde_json::json!({
        "status": "queued",
        "message": "Transcoding started in background"
    })))
}

/// `POST /api/transcode/sweep`
///
/// Triggers a full-library autonomous transcode sweep across all movies and applicable quality presets.
pub async fn transcode_sweep_handler(
    State(state): State<TranscodeState>,
) -> Result<Json<crate::services::transcode_sweeper::SweeperStats>, AppError> {
    let pool = state.pool.as_ref().ok_or_else(|| {
        AppError::Internal("Database connection pool not available".to_string())
    })?;
    let stats = crate::services::transcode_sweeper::TranscodeSweeperService::sweep_once(
        pool,
        &state.roots,
        &state.cache_dir,
    )
    .await?;
    Ok(Json(stats))
}


