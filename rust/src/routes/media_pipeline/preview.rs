use crate::error::AppError;
use crate::models::preview::SeekPreviewMetaResponse;
use crate::services::path_resolver::PathResolver;
use crate::services::preview_service::PreviewService;
use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, Method, Response, StatusCode},
    Json,
};
use sqlx::PgPool;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs::File;
use tokio_util::io::ReaderStream;

#[derive(Clone)]
pub struct PreviewState {
    pub pool: PgPool,
    pub media_roots: Arc<Vec<PathBuf>>,
    pub cache_dir: PathBuf,
}

/// Return seek-preview sampling metadata without generating all thumbnails.
pub async fn get_preview_meta_handler(
    State(state): State<Arc<PreviewState>>,
    Path(filename): Path<String>,
) -> Result<Json<SeekPreviewMetaResponse>, AppError> {
    let clean = filename.trim_start_matches(|c| c == '/' || c == '\\');
    let video_path = PathResolver::resolve_media_path(clean, &state.media_roots)?;
    let duration = PreviewService::get_duration(&video_path, clean, &state.pool).await?;
    let meta = PreviewService::calculate_meta(duration, clean);
    Ok(Json(meta))
}

/// Generate and serve one seek-bar preview thumbnail on demand.
pub async fn get_preview_thumb_handler(
    State(state): State<Arc<PreviewState>>,
    method: Method,
    Path(subpath): Path<String>,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        let mut res = Response::new(Body::empty());
        *res.status_mut() = StatusCode::OK;
        let h = res.headers_mut();
        h.insert("access-control-allow-origin", "*".parse().unwrap());
        h.insert(
            "access-control-allow-methods",
            "GET, HEAD, OPTIONS".parse().unwrap(),
        );
        h.insert(
            "access-control-allow-headers",
            "Range, Origin, Accept, Content-Type".parse().unwrap(),
        );
        h.insert(
            "cross-origin-resource-policy",
            "cross-origin".parse().unwrap(),
        );
        return Ok(res);
    }

    let clean = subpath.trim_start_matches(|c| c == '/' || c == '\\');
    let (rel_video, thumb_name) = clean.rsplit_once('/').ok_or_else(|| {
        AppError::BadRequest("Preview path must include video path and thumbnail name".to_string())
    })?;

    // Validate thumb_{index:05d}.jpg format
    if !thumb_name.starts_with("thumb_") || !thumb_name.ends_with(".jpg") {
        return Err(AppError::NotFound("Invalid thumbnail format".to_string()));
    }
    let digits = &thumb_name[6..thumb_name.len() - 4];
    let index: u64 = digits
        .parse()
        .map_err(|_| AppError::NotFound("Invalid thumbnail index".to_string()))?;

    let video_path = PathResolver::resolve_media_path(rel_video, &state.media_roots)?;
    let duration = PreviewService::get_duration(&video_path, rel_video, &state.pool).await?;
    let meta = PreviewService::calculate_meta(duration, rel_video);

    let clamped_index = index.min(meta.count.saturating_sub(1));
    let preview_dir =
        PreviewService::get_preview_dir(&video_path, &state.cache_dir, &state.media_roots);
    let target = PreviewService::ensure_thumbnail(
        &video_path,
        clamped_index,
        meta.duration,
        meta.interval,
        &preview_dir,
    )
    .await?;

    let file = File::open(&target)
        .await
        .map_err(|e| AppError::NotFound(format!("Thumbnail file missing: {}", e)))?;
    let metadata = file
        .metadata()
        .await
        .map_err(|e| AppError::Internal(e.to_string()))?;
    let total_size = metadata.len();

    let mut res = if method == Method::HEAD {
        Response::new(Body::empty())
    } else {
        let stream = ReaderStream::with_capacity(file, 64 * 1024);
        Response::new(Body::from_stream(stream))
    };

    *res.status_mut() = StatusCode::OK;
    let h = res.headers_mut();
    h.insert(header::CONTENT_TYPE, "image/jpeg".parse().unwrap());
    h.insert(header::CONTENT_LENGTH, total_size.into());
    h.insert(
        header::CACHE_CONTROL,
        "public, max-age=86400".parse().unwrap(),
    );
    h.insert(header::ACCEPT_RANGES, "bytes".parse().unwrap());
    h.insert("access-control-allow-origin", "*".parse().unwrap());
    h.insert(
        "access-control-allow-methods",
        "GET, HEAD, OPTIONS".parse().unwrap(),
    );
    h.insert(
        "cross-origin-resource-policy",
        "cross-origin".parse().unwrap(),
    );

    Ok(res)
}

/// Serve standard WebVTT storyboard mapping seek intervals to preview thumbnail URLs.
pub async fn get_preview_vtt_handler(
    State(state): State<Arc<PreviewState>>,
    method: Method,
    Path(filename): Path<String>,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        let mut res = Response::new(Body::empty());
        *res.status_mut() = StatusCode::OK;
        let h = res.headers_mut();
        h.insert("access-control-allow-origin", "*".parse().unwrap());
        h.insert(
            "access-control-allow-methods",
            "GET, HEAD, OPTIONS".parse().unwrap(),
        );
        h.insert(
            "access-control-allow-headers",
            "Range, Origin, Accept, Content-Type".parse().unwrap(),
        );
        h.insert(
            "cross-origin-resource-policy",
            "cross-origin".parse().unwrap(),
        );
        return Ok(res);
    }

    let clean = filename.trim_start_matches(|c| c == '/' || c == '\\');
    let video_path = PathResolver::resolve_media_path(clean, &state.media_roots)?;
    let duration = PreviewService::get_duration(&video_path, clean, &state.pool).await?;
    let meta = PreviewService::calculate_meta(duration, clean);
    let vtt_text = PreviewService::generate_storyboard_vtt(&meta, clean);

    let mut res = if method == Method::HEAD {
        Response::new(Body::empty())
    } else {
        Response::new(Body::from(vtt_text))
    };

    *res.status_mut() = StatusCode::OK;
    let h = res.headers_mut();
    h.insert(
        header::CONTENT_TYPE,
        "text/vtt; charset=utf-8".parse().unwrap(),
    );
    h.insert(
        header::CACHE_CONTROL,
        "private, max-age=3600".parse().unwrap(),
    );
    h.insert("access-control-allow-origin", "*".parse().unwrap());
    h.insert(
        "access-control-allow-methods",
        "GET, HEAD, OPTIONS".parse().unwrap(),
    );
    h.insert(
        "cross-origin-resource-policy",
        "cross-origin".parse().unwrap(),
    );

    Ok(res)
}
