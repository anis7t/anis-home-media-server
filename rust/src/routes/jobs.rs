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
    let req = body.map(|Json(b)| b).unwrap_or_default();
    let mode = req.mode.clone().unwrap_or_else(|| "hls".to_string());
    let force = req.force.unwrap_or(false);
    let priority = req.priority.unwrap_or(crate::services::job_service::PRIORITY_BACKGROUND);

    let job = JobService::enqueue_with_priority(&state.pool, filename, &mode, force, priority).await?;

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
    let req = body.map(|Json(b)| b).unwrap_or_default();
    let mode = req.mode.clone().unwrap_or_else(|| "hls".to_string());
    let force = req.force.unwrap_or(false);
    let priority = req.priority.unwrap_or(crate::services::job_service::PRIORITY_BACKGROUND);

    let job = JobService::enqueue_with_priority(&state.pool, &filename, &mode, force, priority).await?;

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

/// `GET /api/transcodes` - active background transcodes formatted for web/mobile UI.
pub async fn active_transcodes_handler(
    State(state): State<JobState>,
) -> Result<Json<serde_json::Value>, AppError> {
    let jobs = JobService::list(&state.pool, 50).await?;
    let mut list = Vec::new();
    for j in jobs {
        if j.status == "running" || j.status == "queued" {
            let name_parts = j.filename.rsplit_once('/').map(|(_, n)| n).unwrap_or(&j.filename);
            let title = name_parts.rsplit_once('.').map(|(n, _)| n).unwrap_or(name_parts).replace('.', " ");
            let pct = j.progress.unwrap_or(0.0);
            let speed_str = j.speed.map(|s| format!("{:.1}x", s));
            let eta_str = j.eta.map(|e| {
                let m = (e / 60.0).floor() as u64;
                let s = (e % 60.0).floor() as u64;
                if m >= 60 {
                    format!("{}h {}m", m / 60, m % 60)
                } else {
                    format!("{}m {}s", m, s)
                }
            }).unwrap_or_else(|| "calculating...".to_string());

            let runtime: Option<i32> = sqlx::query_scalar::<_, i32>(
                "SELECT runtime FROM movies WHERE filename = $1",
            )
            .bind(&j.filename)
            .fetch_optional(&*state.pool)
            .await
            .unwrap_or(None);

            let (encoded_str, duration_str) = if let Some(rt_min) = runtime.filter(|&r| r > 0) {
                let dur_sec = (rt_min * 60) as f64;
                let enc_sec = (dur_sec * (pct / 100.0)).clamp(0.0, dur_sec);
                (
                    Some(format!("{}:{:02}", (enc_sec / 60.0).floor() as u64, (enc_sec % 60.0).floor() as u64)),
                    Some(format!("{}:{:02}", (dur_sec / 60.0).floor() as u64, (dur_sec % 60.0).floor() as u64)),
                )
            } else if let (Some(eta_val), Some(spd_val)) = (j.eta, j.speed) {
                if spd_val > 0.05 && pct > 0.0 {
                    let remaining_sec = eta_val;
                    let total_est_sec = remaining_sec / (1.0 - (pct / 100.0)).max(0.01);
                    let enc_sec = (total_est_sec * (pct / 100.0)).max(0.0);
                    (
                        Some(format!("{}:{:02}", (enc_sec / 60.0).floor() as u64, (enc_sec % 60.0).floor() as u64)),
                        Some(format!("{}:{:02}", (total_est_sec / 60.0).floor() as u64, (total_est_sec % 60.0).floor() as u64)),
                    )
                } else {
                    (None, None)
                }
            } else {
                (None, None)
            };

            list.push(serde_json::json!({
                "filename": j.filename,
                "title": title,
                "mode": "Adaptive Transcode (fMP4)",
                "status": j.status,
                "percent": pct,
                "speed": speed_str,
                "eta_str": eta_str,
                "encoded_str": encoded_str,
                "duration_str": duration_str,
                "poster_url": format!("/poster/{}", j.filename),
            }));
        }
    }
    Ok(Json(serde_json::json!({ "transcodes": list })))
}