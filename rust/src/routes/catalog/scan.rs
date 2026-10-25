use crate::error::AppError;
use crate::services::scan_service::{ScanResponse, ScanService};
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::Deserialize;
use sqlx::PgPool;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub struct ScanState {
    pub pool: Arc<PgPool>,
    pub media_roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
    pub tmdb_token: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ScanRequest {
    pub admin_pin: Option<String>,
    pub pin: Option<String>,
}

/// `GET /api/scan`
///
/// Returns current scanning status and transcode queue telemetry,
/// initiating a scan if idle (matching Flask's non-gated GET behaviour).
pub async fn get_scan_handler(
    State(state): State<ScanState>,
) -> Result<Json<ScanResponse>, AppError> {
    let started = ScanService::trigger_scan(
        state.pool.clone(),
        state.media_roots.clone(),
        state.cache_dir.clone(),
        state.tmdb_token.clone(),
    );
    let busy = ScanService::is_busy();
    let last = ScanService::get_last_report().unwrap_or_default();

    Ok(Json(ScanResponse {
        status: if started || busy {
            "scanning".to_string()
        } else {
            "idle".to_string()
        },
        busy,
        files_discovered: last.files_discovered,
        unindexed_discovered: last.unindexed_discovered,
        movies_indexed: last.movies_indexed,
        orphans_pruned: last.orphans_pruned,
        subtitles_acquired: last.subtitles_acquired,
        errors: last.errors,
        transcodes_queued: 0,
        transcodes_started: 0,
        transcodes_skipped: 0,
        transcodes_errors: 0,
    }))
}

/// `POST /api/scan`
///
/// Triggers library scan and missing transcode queueing.
/// Administrator-gated: requires either a valid `X-Admin-Pin` header or body `{ "admin_pin": "..." }`.
/// Fails closed (HTTP 403) if unauthenticated or if no PIN is configured.
pub async fn post_scan_handler(
    State(state): State<ScanState>,
    headers: HeaderMap,
    body: Option<Json<ScanRequest>>,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    let body_pin = body.and_then(|Json(b)| b.admin_pin.or(b.pin));
    let authorized =
        ScanService::is_admin_authorized(&state.pool, &headers, body_pin.as_deref()).await;

    if !authorized {
        return Ok((
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "error": "Administrator verification required to trigger library scan."
            })),
        ));
    }

    let started = ScanService::trigger_scan(
        state.pool.clone(),
        state.media_roots.clone(),
        state.cache_dir.clone(),
        state.tmdb_token.clone(),
    );
    let busy = ScanService::is_busy();
    let last = ScanService::get_last_report().unwrap_or_default();

    Ok((
        StatusCode::OK,
        Json(serde_json::json!({
            "success": true,
            "status": if started || busy { "scanning" } else { "idle" },
            "busy": busy,
            "files_discovered": last.files_discovered,
            "unindexed_discovered": last.unindexed_discovered,
            "movies_indexed": last.movies_indexed,
            "orphans_pruned": last.orphans_pruned,
            "errors": last.errors,
            "transcodes_queued": 0,
            "transcodes_started": 0,
            "transcodes_skipped": 0,
            "transcodes_errors": 0,
        })),
    ))
}
