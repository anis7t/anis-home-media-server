use crate::error::AppError;
use crate::services::hls_service::HlsService;
use crate::services::path_resolver::PathResolver;
use crate::services::range_service::RangeService;
use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderMap, Method, Response, StatusCode},
};
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub struct HlsState {
    pub roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
}

pub async fn hls_handler(
    State(state): State<HlsState>,
    headers: HeaderMap,
    method: Method,
    Path(path): Path<String>,
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

    let (filename, target) = match path.rsplit_once('/') {
        Some((f, t)) => (f, t),
        None => return Err(AppError::NotFound("Invalid HLS path format".to_string())),
    };

    // Traversal safety: filename and target must not escape
    if target.contains("..") || target.contains('/') || target.contains('\\') {
        return Err(AppError::NotFound("Invalid HLS path".to_string()));
    }

    // Check if filename contains a quality subpath e.g. "movie.mkv/1080p"
    let (raw_filename, quality) = match filename.rsplit_once('/') {
        Some((parent, possible_quality))
            if crate::services::chunk_transcode::ChunkTranscodeService::is_quality_string(possible_quality) =>
        {
            (parent, Some(possible_quality))
        }
        _ => (filename, None),
    };

    let video_path = PathResolver::resolve_media_path(raw_filename, &state.roots)?;
    let hls_dir = HlsService::find_hls_quality_dir(&video_path, &state.roots, &state.cache_dir, quality);

    if target == "playlist.m3u8" {
        let playlist_file = hls_dir.join("playlist.m3u8");
        if playlist_file.is_file() {
            let content = tokio::fs::read_to_string(&playlist_file)
                .await
                .map_err(|e| AppError::Internal(e.to_string()))?;

            if content.contains("segment_") {
                let honest_content = HlsService::honest_target_duration(&content);

                let mut res = Response::new(Body::from(honest_content));
                *res.status_mut() = StatusCode::OK;
                let h = res.headers_mut();
                h.insert(header::CONTENT_TYPE, "application/vnd.apple.mpegurl".parse().unwrap());
                h.insert(header::CACHE_CONTROL, "no-cache, max-age=0".parse().unwrap());
                h.insert("access-control-allow-origin", "*".parse().unwrap());
                h.insert("access-control-allow-methods", "GET, HEAD, OPTIONS".parse().unwrap());
                h.insert("access-control-allow-headers", "Range, Origin, Accept, Content-Type".parse().unwrap());
                h.insert("access-control-expose-headers", "Content-Length, Content-Range, Accept-Ranges".parse().unwrap());
                h.insert("cross-origin-resource-policy", "cross-origin".parse().unwrap());
                return Ok(res);
            }
        }

        // Playlist does not exist yet or has no segments: return 503 retry response
        let empty_body = "#EXTM3U\n#EXT-X-VERSION:7\n";
        let mut res = Response::new(Body::from(empty_body));
        *res.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
        let h = res.headers_mut();
        h.insert(header::CONTENT_TYPE, "application/vnd.apple.mpegurl".parse().unwrap());
        h.insert(header::CACHE_CONTROL, "no-cache, no-store, must-revalidate".parse().unwrap());
        h.insert(header::RETRY_AFTER, "1".parse().unwrap());
        h.insert("access-control-allow-origin", "*".parse().unwrap());
        h.insert("access-control-allow-methods", "GET, HEAD, OPTIONS".parse().unwrap());
        h.insert("access-control-allow-headers", "Range, Origin, Accept, Content-Type".parse().unwrap());
        h.insert("access-control-expose-headers", "Content-Length, Content-Range, Accept-Ranges".parse().unwrap());
        h.insert("cross-origin-resource-policy", "cross-origin".parse().unwrap());
        return Ok(res);
    }

    if HlsService::is_valid_segment_name(target) {
        let segment_file = hls_dir.join(target);
        if !segment_file.is_file() {
            return Err(AppError::NotFound(format!("Segment {} not found", target)));
        }

        let mut res = RangeService::stream_file(segment_file, headers, method).await?;
        let seg_mimetype = if target.ends_with(".ts") {
            "video/mp2t"
        } else if target.ends_with(".m4s") {
            "video/iso.segment"
        } else {
            "video/mp4"
        };

        let h = res.headers_mut();
        h.insert(header::CONTENT_TYPE, seg_mimetype.parse().unwrap());
        h.insert(header::CACHE_CONTROL, "public, max-age=3600".parse().unwrap());
        h.insert("access-control-allow-origin", "*".parse().unwrap());
        h.insert("access-control-allow-methods", "GET, HEAD, OPTIONS".parse().unwrap());
        h.insert("access-control-allow-headers", "Range, Origin, Accept, Content-Type".parse().unwrap());
        h.insert("access-control-expose-headers", "Content-Length, Content-Range, Accept-Ranges".parse().unwrap());
        h.insert("cross-origin-resource-policy", "cross-origin".parse().unwrap());
        return Ok(res);
    }

    Err(AppError::NotFound(format!("Unrecognized HLS target: {}", target)))
}
