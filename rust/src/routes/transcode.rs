use crate::error::AppError;
use crate::models::transcode::TranscodeStatusResponse;
use crate::services::hls_service::HlsService;
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

#[derive(Clone)]
pub struct TranscodeState {
    pub roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
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
