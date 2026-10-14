use crate::error::AppError;
use crate::models::subtitle::{SubtitleListResponse, SubtitleUploadResponse};
use crate::services::path_resolver::PathResolver;
use crate::services::subtitle_service::SubtitleService;
use axum::{
    body::Body,
    extract::{Multipart, Path, Query, State},
    http::{header, HeaderMap, Method, Response, StatusCode},
    Json,
};
use serde::Deserialize;
use std::path::{Path as StdPath, PathBuf};
use std::sync::Arc;

#[derive(Debug, Deserialize, Default)]
pub struct SubtitleQuery {
    pub offset: Option<f64>,
}

/// Serve sidecar subtitle file converted on-the-fly to WebVTT format.
pub async fn subtitle_stream_handler(
    State(roots): State<Arc<Vec<PathBuf>>>,
    _headers: HeaderMap,
    method: Method,
    Query(query): Query<SubtitleQuery>,
    Path(subpath): Path<String>,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        let mut res = Response::new(Body::empty());
        *res.status_mut() = StatusCode::OK;
        let h = res.headers_mut();
        h.insert("access-control-allow-origin", "*".parse().unwrap());
        h.insert("access-control-allow-methods", "GET, HEAD, OPTIONS".parse().unwrap());
        h.insert("access-control-allow-headers", "Range, Origin, Accept, Content-Type".parse().unwrap());
        h.insert("cross-origin-resource-policy", "cross-origin".parse().unwrap());
        return Ok(res);
    }

    let clean = subpath.trim_start_matches(|c| c == '/' || c == '\\');
    let (rel_video, sub_name) = clean.rsplit_once('/').ok_or_else(|| {
        AppError::BadRequest("Subtitle path must include video path and subtitle filename".to_string())
    })?;

    let video_path = PathResolver::resolve_media_path(rel_video, &roots)?;
    let sub_file = SubtitleService::resolve_sidecar_file(&video_path, sub_name, &roots)?;

    let content = tokio::fs::read_to_string(&sub_file)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to read subtitle file: {}", e)))?;

    let offset_sec = query.offset.unwrap_or(0.0);
    let vtt_text = SubtitleService::srt_to_vtt(&content, offset_sec);

    let mut res = if method == Method::HEAD {
        Response::new(Body::empty())
    } else {
        Response::new(Body::from(vtt_text))
    };

    *res.status_mut() = StatusCode::OK;
    let h = res.headers_mut();
    h.insert(header::CONTENT_TYPE, "text/vtt; charset=utf-8".parse().unwrap());
    h.insert(header::CACHE_CONTROL, "private, max-age=3600".parse().unwrap());
    h.insert("access-control-allow-origin", "*".parse().unwrap());
    h.insert("access-control-allow-methods", "GET, HEAD, OPTIONS".parse().unwrap());
    h.insert("access-control-allow-headers", "Range, Origin, Accept, Content-Type".parse().unwrap());
    h.insert("cross-origin-resource-policy", "cross-origin".parse().unwrap());

    Ok(res)
}

/// Return JSON listing of all available subtitle tracks for a movie.
pub async fn list_subtitles_handler(
    State(roots): State<Arc<Vec<PathBuf>>>,
    Path(filename): Path<String>,
) -> Result<Json<SubtitleListResponse>, AppError> {
    let video_path = PathResolver::resolve_media_path(&filename, &roots)?;
    let tracks = SubtitleService::list_tracks(&video_path, &filename, &roots);
    Ok(Json(SubtitleListResponse { tracks }))
}

/// Upload a subtitle file (.srt or .vtt), auto-detect language, and save next to the media.
pub async fn upload_subtitle_handler(
    State(roots): State<Arc<Vec<PathBuf>>>,
    Path(filename): Path<String>,
    mut multipart: Multipart,
) -> Result<Json<SubtitleUploadResponse>, AppError> {
    let video_path = PathResolver::resolve_media_path(&filename, &roots)?;
    let parent_dir = video_path.parent().ok_or_else(|| {
        AppError::NotFound("Target video directory not found".to_string())
    })?;

    let mut found_file = None;
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::BadRequest(e.to_string()))?
    {
        let name = field.name().unwrap_or("").to_string();
        if name == "subtitle" {
            let original_name = field.file_name().unwrap_or("").to_string();
            let bytes = field
                .bytes()
                .await
                .map_err(|e| AppError::BadRequest(e.to_string()))?;
            found_file = Some((original_name, bytes));
            break;
        }
    }

    let (original_name, bytes) = found_file.ok_or_else(|| {
        AppError::BadRequest("No subtitle file provided in multipart field 'subtitle'.".to_string())
    })?;

    let ext = StdPath::new(&original_name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    if ext != "srt" && ext != "vtt" {
        return Err(AppError::UnsupportedMediaType(format!(
            "Unsupported format '.{}'. Only .srt and .vtt are accepted.",
            ext
        )));
    }

    let text = String::from_utf8_lossy(&bytes);
    let lang = SubtitleService::detect_subtitle_language(&text);
    let short_name = SubtitleService::get_short_movie_name(&video_path);

    let mut counter = 1;
    let (dest_name, dest_path) = loop {
        let name = format!("{}_{}_{}.{}", short_name, lang, counter, ext);
        let path = parent_dir.join(&name);
        if !path.exists() {
            break (name, path);
        }
        counter += 1;
    };

    tokio::fs::write(&dest_path, &bytes)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to write subtitle file: {}", e)))?;

    Ok(Json(SubtitleUploadResponse {
        success: true,
        filename: dest_name,
        language: lang,
        path: dest_path.to_string_lossy().to_string(),
    }))
}
