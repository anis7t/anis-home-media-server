use crate::error::AppError;
use crate::models::job::{EnqueueJobRequest, TranscodeJob};
use crate::services::job_service::JobService;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use sqlx::PgPool;
use std::sync::Arc;

#[derive(Clone)]
pub struct JobState {
    pub pool: Arc<PgPool>,
}

/// `POST /api/transcode/jobs/{*path}` - single entry point for job actions.
///
/// The tail is dispatched internally: a `.../cancel` suffix cancels, anything
/// else is treated as a filename and enqueued. Registering separate
/// `/jobs/{*filename}` and `/jobs/{*filename}/cancel` routes is not possible:
/// axum's radix router rejects the second as conflicting with the first, and
/// that conflict panics the whole router at startup (AGENTS.md §9).
pub async fn jobs_dispatch_handler(
    State(state): State<JobState>,
    Path(path): Path<String>,
    body: Option<Json<EnqueueJobRequest>>,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    let decoded = percent_decode(&path);
    if let Some(filename) = decoded.strip_suffix("/cancel") {
        if filename.is_empty() {
            return Err(AppError::BadRequest("Filename is required".to_string()));
        }
        let body = cancel_job_inner(state, filename).await?;
        return Ok((StatusCode::OK, body));
    }
    if decoded.is_empty() {
        return Err(AppError::BadRequest("Filename is required".to_string()));
    }
    enqueue_job_inner(state, &decoded, body).await
}

/// Job filenames legitimately contain spaces, brackets and Unicode, so a
/// wildcard path arrives percent-encoded.
pub fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(v) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).replace('+', " ")
}

async fn enqueue_job_inner(
    state: JobState,
    filename: &str,
    body: Option<Json<EnqueueJobRequest>>,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    let req = body.map(|Json(b)| b).unwrap_or(EnqueueJobRequest {
        mode: None,
        force: None,
    });
    let mode = req.mode.clone().unwrap_or_else(|| "hls".to_string());
    let force = req.force.unwrap_or(false);

    let job = JobService::enqueue(&state.pool, filename, &mode, force).await?;

    Ok((
        StatusCode::ACCEPTED,
        Json(serde_json::json!({ "job": job })),
    ))
}

async fn cancel_job_inner(
    state: JobState,
    filename: &str,
) -> Result<Json<serde_json::Value>, AppError> {
    let mode = "hls";
    let job = JobService::get_by_filename(&state.pool, filename, mode).await?;
    match job {
        Some(j) => {
            // No owner supplied from the API: only a queued job may be
            // canceled this way. A running job must be canceled by its
            // lease owner, which is the worker loop (6C).
            let canceled = JobService::cancel(&state.pool, j.id, None).await?;
            let current = JobService::get_by_id(&state.pool, j.id).await?;
            Ok(Json(serde_json::json!({
                "canceled": canceled,
                "job": current,
            })))
        }
        None => Ok(Json(serde_json::json!({
            "canceled": false,
            "job": serde_json::Value::Null,
            "message": "No job for this filename",
        }))),
    }
}

/// `POST /api/transcode/jobs/{filename}` - idempotent admission.
/// Returns 202 with the (possibly pre-existing) job. A title already in a
/// live state is not queued twice.
pub async fn enqueue_job_handler(
    State(state): State<JobState>,
    Path(filename): Path<String>,
    body: Option<Json<EnqueueJobRequest>>,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    let req = body.map(|Json(b)| b).unwrap_or(EnqueueJobRequest {
        mode: None,
        force: None,
    });
    let mode = req.mode.clone().unwrap_or_else(|| "hls".to_string());
    let force = req.force.unwrap_or(false);

    let job = JobService::enqueue(&state.pool, &filename, &mode, force).await?;

    Ok((
        StatusCode::ACCEPTED,
        Json(serde_json::json!({ "job": job })),
    ))
}

/// `POST /api/transcode/jobs/{filename}/cancel`
pub async fn cancel_job_handler(
    State(state): State<JobState>,
    Path(filename): Path<String>,
) -> Result<Json<serde_json::Value>, AppError> {
    let mode = "hls";
    let job = JobService::get_by_filename(&state.pool, &filename, mode).await?;
    match job {
        Some(j) => {
            // No owner supplied from the API: only a queued job may be
            // canceled this way. A running job must be canceled by its
            // lease owner, which is the worker loop (6C).
            let canceled = JobService::cancel(&state.pool, j.id, None).await?;
            let current = JobService::get_by_id(&state.pool, j.id).await?;
            Ok(Json(serde_json::json!({
                "canceled": canceled,
                "job": current,
            })))
        }
        None => Ok(Json(serde_json::json!({
            "canceled": false,
            "job": serde_json::Value::Null,
            "message": "No job for this filename",
        }))),
    }
}

/// `GET /api/transcode/jobs` - recent jobs, newest first.
pub async fn list_jobs_handler(
    State(state): State<JobState>,
) -> Result<Json<serde_json::Value>, AppError> {
    let jobs: Vec<TranscodeJob> = JobService::list(&state.pool, 100).await?;
    Ok(Json(serde_json::json!({ "jobs": jobs })))
}