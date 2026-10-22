use crate::error::AppError;
use crate::models::upload::{
    ChunkAppendResponse, ChunkInitRequest, ChunkStatusResponse, UploadManifest,
    UploadSuccessResponse,
};
use crate::services::auth_service::AuthService;
use crate::services::upload_service as uploads;
use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, Multipart, Path, State},
    http::{HeaderMap, StatusCode},
    routing::{get, post},
    Json, Router,
};
use serde_json::json;
use sqlx::PgPool;
use std::path::{Path as StdPath, PathBuf};
use std::sync::Arc;
use tokio::io::AsyncWriteExt;

/// 256 MiB is the compatibility cap for the single-file route. Anything larger
/// uses the resumable chunked route (8 MiB chunks, 20 GiB total).
const SINGLE_UPLOAD_MAX: usize = 256 * 1024 * 1024;

#[derive(Clone)]
pub struct UploadState {
    pub pool: Arc<PgPool>,
    /// Used to compute the catalog-relative filename.
    pub media_root: PathBuf,
    pub upload_tmp: PathBuf,
    pub upload_target_dir: PathBuf,
    /// Production calls `ScanService::trigger_scan`; tests inject a no-op.
    pub scan_trigger: Arc<dyn Fn() -> bool + Send + Sync>,
}

pub fn build_upload_routes(state: UploadState) -> Router {
    let chunk_limit = uploads::CHUNK_SIZE.saturating_add(64 * 1024) as usize;

    Router::new()
        .route(
            "/api/upload",
            post(single_file_handler).layer(DefaultBodyLimit::max(SINGLE_UPLOAD_MAX)),
        )
        .route("/api/upload/chunk/init", post(init_handler))
        .route(
            "/api/upload/chunk/{upload_id}",
            get(status_handler)
                .post(chunk_handler)
                .delete(delete_handler)
                .layer(DefaultBodyLimit::max(chunk_limit)),
        )
        .route(
            "/api/upload/chunk/{upload_id}/complete",
            post(complete_handler),
        )
        .with_state(state)
}

async fn require_admin(state: &UploadState, headers: &HeaderMap) -> Result<(), AppError> {
    if AuthService::is_admin_authorized(&state.pool, headers, None).await {
        Ok(())
    } else {
        Err(AppError::Forbidden(
            "Administrator verification required to upload media.".to_string(),
        ))
    }
}

fn multipart_error(err: impl std::fmt::Display) -> AppError {
    let message = err.to_string();
    let lower = message.to_ascii_lowercase();
    if lower.contains("length limit")
        || lower.contains("too large")
        || lower.contains("body limit")
    {
        AppError::PayloadTooLarge("Upload exceeds the route body limit.".to_string())
    } else {
        AppError::BadRequest(message)
    }
}

fn offset_from_headers(headers: &HeaderMap) -> Result<u64, AppError> {
    match headers.get("X-Upload-Offset") {
        None => Ok(0),
        Some(value) => value
            .to_str()
            .ok()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .ok_or_else(|| {
                AppError::BadRequest("Invalid X-Upload-Offset header".to_string())
            }),
    }
}

async fn part_size(part_path: &StdPath) -> u64 {
    tokio::fs::metadata(part_path)
        .await
        .map(|m| m.len())
        .unwrap_or(0)
}

/// `POST /api/upload/chunk/init`
pub async fn init_handler(
    State(state): State<UploadState>,
    headers: HeaderMap,
    Json(req): Json<ChunkInitRequest>,
) -> Result<Json<ChunkStatusResponse>, AppError> {
    require_admin(&state, &headers).await?;

    if req.size == 0 {
        return Err(AppError::BadRequest(
            "Upload size must be greater than zero".to_string(),
        ));
    }
    if req.size > uploads::MAX_UPLOAD_BYTES {
        return Err(AppError::PayloadTooLarge(format!(
            "Upload exceeds the {} GiB cap",
            uploads::MAX_UPLOAD_BYTES / (1024 * 1024 * 1024)
        )));
    }

    let filename = uploads::sanitize_filename(&req.filename)?;
    let title = req
        .title
        .as_deref()
        .map(uploads::sanitize_title)
        .filter(|s| !s.is_empty());

    uploads::cleanup_stale(&state.upload_tmp, 24 * 60 * 60).await;

    let upload_id = AuthService::generate_random_token()?;
    let manifest = UploadManifest {
        filename: filename.clone(),
        size: req.size,
        created_at: chrono::Utc::now().timestamp(),
        title,
        overwrite: req.overwrite.unwrap_or(false),
    };

    uploads::create_session(&state.upload_tmp, &upload_id, &manifest).await?;

    Ok(Json(ChunkStatusResponse {
        success: true,
        upload_id,
        filename,
        size: req.size,
        offset: 0,
        chunk_size: uploads::CHUNK_SIZE,
    }))
}

/// `GET /api/upload/chunk/{upload_id}`
pub async fn status_handler(
    State(state): State<UploadState>,
    Path(upload_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<ChunkStatusResponse>, AppError> {
    require_admin(&state, &headers).await?;
    uploads::validate_upload_id(&upload_id)?;

    let manifest = uploads::read_manifest(&state.upload_tmp, &upload_id).await?;
    let (_, part_path) = uploads::session_paths(&state.upload_tmp, &upload_id);
    let offset = part_size(&part_path).await;

    Ok(Json(ChunkStatusResponse {
        success: true,
        upload_id,
        filename: manifest.filename,
        size: manifest.size,
        offset,
        chunk_size: uploads::CHUNK_SIZE,
    }))
}

/// `POST /api/upload/chunk/{upload_id}` — raw `application/octet-stream`.
pub async fn chunk_handler(
    State(state): State<UploadState>,
    Path(upload_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    require_admin(&state, &headers).await?;
    uploads::validate_upload_id(&upload_id)?;

    let manifest = uploads::read_manifest(&state.upload_tmp, &upload_id).await?;
    let (_, part_path) = uploads::session_paths(&state.upload_tmp, &upload_id);
    let current = part_size(&part_path).await;
    let offset = offset_from_headers(&headers)?;

    if offset != current {
        return Ok((
            StatusCode::CONFLICT,
            Json(json!({
                "error": "Upload offset mismatch",
                "current_offset": current,
            })),
        ));
    }

    if body.is_empty() {
        return Err(AppError::BadRequest("Empty upload chunk".to_string()));
    }
    if body.len() as u64 > uploads::CHUNK_SIZE {
        return Err(AppError::PayloadTooLarge(format!(
            "Chunk exceeds the {} MiB limit",
            uploads::CHUNK_SIZE / (1024 * 1024)
        )));
    }
    if offset.saturating_add(body.len() as u64) > manifest.size {
        return Err(AppError::BadRequest(
            "Chunk extends past the declared upload size".to_string(),
        ));
    }

    let new_offset = uploads::append_chunk(&part_path, offset, &body).await?;
    let response = ChunkAppendResponse {
        success: true,
        upload_id,
        offset: new_offset,
        size: manifest.size,
        complete: new_offset == manifest.size,
    };

    Ok((StatusCode::OK, Json(json!(response))))
}

/// `DELETE /api/upload/chunk/{upload_id}`
pub async fn delete_handler(
    State(state): State<UploadState>,
    Path(upload_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, AppError> {
    require_admin(&state, &headers).await?;
    uploads::validate_upload_id(&upload_id)?;
    uploads::abandon_session(&state.upload_tmp, &upload_id).await?;
    Ok(Json(json!({ "success": true })))
}

/// `POST /api/upload/chunk/{upload_id}/complete`
pub async fn complete_handler(
    State(state): State<UploadState>,
    Path(upload_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<UploadSuccessResponse>, AppError> {
    require_admin(&state, &headers).await?;
    uploads::validate_upload_id(&upload_id)?;

    let manifest = uploads::read_manifest(&state.upload_tmp, &upload_id).await?;
    let target = uploads::finalize_session(
        &state.upload_tmp,
        &state.upload_target_dir,
        &upload_id,
    )
    .await?;

    let response = build_success(
        &state,
        &target,
        &manifest.filename,
        manifest.title.as_deref(),
    )
    .await?;

    Ok(Json(response))
}

/// Insert the fallback catalog row, trigger the library scan, and build the
/// response shared by the single-file and chunked completion paths.
async fn build_success(
    state: &UploadState,
    target: &StdPath,
    original_name: &str,
    title_override: Option<&str>,
) -> Result<UploadSuccessResponse, AppError> {
    let filename = uploads::relative_filename(target, &state.media_root);
    let (parsed_title, year) = uploads::parse_title_year(original_name);
    let title = title_override
        .map(uploads::sanitize_title)
        .filter(|s| !s.is_empty())
        .unwrap_or(parsed_title);

    // The scan will enrich this row. Inserting it first makes the details link
    // work immediately; a transient DB failure must not fail the upload.
    if let Err(err) = sqlx::query(
        r#"
        INSERT INTO movies (filename, title, year)
        VALUES ($1, $2, $3)
        ON CONFLICT (filename) DO NOTHING
        "#,
    )
    .bind(&filename)
    .bind(&title)
    .bind(year)
    .execute(&*state.pool)
    .await
    {
        tracing::warn!("Failed to insert fallback movie row for {}: {}", filename, err);
    }

    let _ = (state.scan_trigger.as_ref())();

    Ok(UploadSuccessResponse {
        success: true,
        filename: filename.clone(),
        title,
        year,
        needs_transcode: uploads::needs_transcode(original_name),
        details_url: format!("/movie/{}", filename),
    })
}

/// `POST /api/upload` — compatibility route for a single multipart file. The
/// React UI uses the chunked route; this preserves the Flask-era API.
pub async fn single_file_handler(
    State(state): State<UploadState>,
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Result<Json<UploadSuccessResponse>, AppError> {
    require_admin(&state, &headers).await?;

    tokio::fs::create_dir_all(&state.upload_target_dir)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to create upload target dir: {}", e)))?;

    let temp_token = AuthService::generate_random_token()?;
    let temp_path = state
        .upload_target_dir
        .join(format!(".upload_{}.part", temp_token));

    let mut original_name: Option<String> = None;
    let mut title: Option<String> = None;
    let mut overwrite = false;
    let mut wrote_file = false;

    while let Some(mut field) = multipart
        .next_field()
        .await
        .map_err(multipart_error)?
    {
        match field.name().unwrap_or("") {
            "file" => {
                if wrote_file {
                    let _ = tokio::fs::remove_file(&temp_path).await;
                    return Err(AppError::BadRequest(
                        "Only one file is accepted per upload".to_string(),
                    ));
                }

                let raw_name = field.file_name().unwrap_or("").to_string();
                let sanitized = uploads::sanitize_filename(&raw_name)?;
                original_name = Some(sanitized);

                let stream_result: Result<(), AppError> = async {
                    let mut file = tokio::fs::File::create(&temp_path)
                        .await
                        .map_err(|e| AppError::Internal(format!("Failed to create upload temp file: {}", e)))?;
                    while let Some(chunk) = field.chunk().await.map_err(multipart_error)? {
                        file.write_all(&chunk).await.map_err(|e| {
                            AppError::Internal(format!("Failed to write upload temp file: {}", e))
                        })?;
                    }
                    file.sync_all().await.map_err(|e| {
                        AppError::Internal(format!("Failed to sync upload temp file: {}", e))
                    })?;
                    Ok(())
                }
                .await;

                if let Err(err) = stream_result {
                    let _ = tokio::fs::remove_file(&temp_path).await;
                    return Err(err);
                }
                wrote_file = true;
            }
            "title" => {
                let value = field.text().await.map_err(multipart_error)?;
                let cleaned = uploads::sanitize_title(&value);
                title = if cleaned.is_empty() { None } else { Some(cleaned) };
            }
            "overwrite" => {
                let value = field.text().await.map_err(multipart_error)?;
                overwrite = matches!(
                    value.trim().to_ascii_lowercase().as_str(),
                    "1" | "true"
                );
            }
            _ => {}
        }
    }

    let Some(original_name) = original_name else {
        let _ = tokio::fs::remove_file(&temp_path).await;
        return Err(AppError::BadRequest(
            "No file uploaded. Please select a video file.".to_string(),
        ));
    };
    if !wrote_file {
        let _ = tokio::fs::remove_file(&temp_path).await;
        return Err(AppError::BadRequest(
            "No file selected for upload.".to_string(),
        ));
    }

    let target_name = match uploads::build_target_name(&original_name, title.as_deref()) {
        Ok(name) => name,
        Err(err) => {
            let _ = tokio::fs::remove_file(&temp_path).await;
            return Err(err);
        }
    };
    let target = uploads::unique_target_path(
        &state.upload_target_dir,
        &target_name,
        overwrite,
    );

    if overwrite && target.exists() {
        let _ = tokio::fs::remove_file(&target).await;
    }

    if let Err(rename_err) = tokio::fs::rename(&temp_path, &target).await {
        if let Err(copy_err) = tokio::fs::copy(&temp_path, &target).await {
            let _ = tokio::fs::remove_file(&temp_path).await;
            let _ = tokio::fs::remove_file(&target).await;
            return Err(AppError::Internal(format!(
                "Failed to move upload into place (rename: {}; copy: {})",
                rename_err, copy_err
            )));
        }
        let _ = tokio::fs::remove_file(&temp_path).await;
    }

    let response = build_success(&state, &target, &original_name, title.as_deref()).await?;
    Ok(Json(response))
}
