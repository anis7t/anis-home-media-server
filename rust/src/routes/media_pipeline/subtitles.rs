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
use sqlx::PgPool;
use std::path::{Path as StdPath, PathBuf};
use std::sync::Arc;

#[derive(Clone)]
pub struct SubtitleState {
    pub roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
    pub pool: PgPool,
}

#[derive(Debug, Deserialize, Default)]
pub struct SubtitleQuery {
    pub offset: Option<f64>,
}

fn make_vtt_response(vtt_text: String, method: Method) -> Response<Body> {
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
        "access-control-allow-headers",
        "Range, Origin, Accept, Content-Type".parse().unwrap(),
    );
    h.insert(
        "cross-origin-resource-policy",
        "cross-origin".parse().unwrap(),
    );

    res
}

/// Serve subtitle file (sidecar, embedded, or online) converted on-the-fly to standard WebVTT format.
pub async fn subtitle_stream_handler(
    State(state): State<SubtitleState>,
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

    let clean = subpath.trim_start_matches(['/', '\\']);

    // 1. Embedded subtitles: /subtitles/embedded/<rel_video>/<stream_idx>.vtt
    if let Some(rest) = clean.strip_prefix("embedded/") {
        let (rel_video, stream_file) = rest.rsplit_once('/').ok_or_else(|| {
            AppError::BadRequest(
                "Embedded subtitle path must include video path and stream index".to_string(),
            )
        })?;
        let stream_idx: usize = stream_file
            .strip_suffix(".vtt")
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| {
                AppError::BadRequest("Invalid stream index in embedded subtitle path".to_string())
            })?;

        let video_path = PathResolver::resolve_media_path(rel_video, &state.roots)?;
        let vtt_path =
            SubtitleService::extract_embedded_subtitle(&video_path, stream_idx, &state.cache_dir)
                .await?;
        let content = tokio::fs::read_to_string(&vtt_path)
            .await
            .map_err(|e| AppError::Internal(format!("Failed to read embedded subtitle: {}", e)))?;

        let offset_sec = query.offset.unwrap_or(0.0);
        let vtt_text = if offset_sec != 0.0 {
            SubtitleService::srt_to_vtt(&content, offset_sec)
        } else {
            content
        };
        return Ok(make_vtt_response(vtt_text, method));
    }

    // 2. Online subtitles: /subtitles/online/<rel_video>.vtt
    if let Some(rest) = clean.strip_prefix("online/") {
        let rel_video = rest.strip_suffix(".vtt").ok_or_else(|| {
            AppError::BadRequest("Online subtitle path must end with .vtt".to_string())
        })?;

        let video_path = PathResolver::resolve_media_path(rel_video, &state.roots)?;
        let movie_title: Option<String> =
            sqlx::query_scalar("SELECT title FROM movies WHERE filename = $1")
                .bind(rel_video)
                .fetch_optional(&state.pool)
                .await
                .ok()
                .flatten();

        let title = movie_title.unwrap_or_default();
        let vtt_path =
            SubtitleService::fetch_online_subtitle(&video_path, &title, &state.cache_dir)
                .await
                .ok_or_else(|| AppError::NotFound("Online subtitle not found".to_string()))?;

        let content = tokio::fs::read_to_string(&vtt_path)
            .await
            .map_err(|e| AppError::Internal(format!("Failed to read online subtitle: {}", e)))?;

        let offset_sec = query.offset.unwrap_or(0.0);
        let vtt_text = if offset_sec != 0.0 {
            SubtitleService::srt_to_vtt(&content, offset_sec)
        } else {
            content
        };
        return Ok(make_vtt_response(vtt_text, method));
    }

    // 3. Local sidecar subtitles: /subtitles/<rel_video>/<sub_name>
    let (rel_video, sub_name) = clean.rsplit_once('/').ok_or_else(|| {
        AppError::BadRequest(
            "Subtitle path must include video path and subtitle filename".to_string(),
        )
    })?;

    let video_path = PathResolver::resolve_media_path(rel_video, &state.roots)?;
    let sub_file = SubtitleService::resolve_sidecar_file(&video_path, sub_name, &state.roots)?;

    let content = tokio::fs::read_to_string(&sub_file)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to read subtitle file: {}", e)))?;

    let offset_sec = query.offset.unwrap_or(0.0);
    let vtt_text = SubtitleService::srt_to_vtt(&content, offset_sec);

    Ok(make_vtt_response(vtt_text, method))
}

/// Return JSON listing of all available subtitle tracks for a movie (sidecars, embedded, online).
pub async fn list_subtitles_handler(
    State(state): State<SubtitleState>,
    Path(filename): Path<String>,
) -> Result<Json<SubtitleListResponse>, AppError> {
    let video_path = PathResolver::resolve_media_path(&filename, &state.roots)?;

    let movie_title: Option<String> =
        sqlx::query_scalar("SELECT title FROM movies WHERE filename = $1")
            .bind(&filename)
            .fetch_optional(&state.pool)
            .await
            .ok()
            .flatten();

    let tracks = SubtitleService::list_tracks_async(
        &video_path,
        &filename,
        &state.roots,
        &state.cache_dir,
        movie_title.as_deref(),
    )
    .await;

    Ok(Json(SubtitleListResponse { tracks }))
}

/// Upload a subtitle file (.srt or .vtt), auto-detect language, and save next to the media.
pub async fn upload_subtitle_handler(
    State(state): State<SubtitleState>,
    Path(filename): Path<String>,
    mut multipart: Multipart,
) -> Result<Json<SubtitleUploadResponse>, AppError> {
    let video_path = PathResolver::resolve_media_path(&filename, &state.roots)?;
    let parent_dir = video_path
        .parent()
        .ok_or_else(|| AppError::NotFound("Target video directory not found".to_string()))?;

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
