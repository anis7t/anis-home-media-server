use crate::error::AppError;
use crate::models::storage::{
    PurgeOrphansRequest, PurgeOrphansResponse, StorageAuditResponse, StorageSettingsResponse,
    StorageSettingsUpdateRequest,
};
use crate::services::audit_service::AuditService;
use crate::services::auth_service::AuthService;
use crate::services::storage_service::{StorageService, ALLOWED_RETENTION_POLICIES};
use crate::services::system_service::SystemService;
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use sqlx::PgPool;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub struct StorageState {
    pub pool: Arc<PgPool>,
    pub media_roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
    pub system_service: SystemService,
}

/// `GET /api/storage/audit`
///
/// Audit HLS and preview cache directories for active vs orphaned status.
/// Administrator-gated: requires valid `X-Admin-Pin` header or body PIN.
/// Supports `?force=true` query parameter to bypass 60s in-memory TTL cache.
pub async fn storage_audit_handler(
    State(state): State<StorageState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Result<Json<StorageAuditResponse>, (StatusCode, Json<serde_json::Value>)> {
    if !AuthService::is_admin_authorized(&state.pool, &headers, None).await {
        return Err((
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "success": false,
                "error": "Unauthorized"
            })),
        ));
    }

    let force = query
        .get("force")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("yes"))
        .unwrap_or(false);

    let report = StorageService::audit_caches(
        &state.pool,
        &state.media_roots,
        &state.cache_dir,
        &state.system_service,
        force,
    )
    .await;

    Ok(Json(report))
}

/// `POST /api/storage/purge-orphans`
///
/// Purge all verified orphaned HLS and preview cache directories.
/// Administrator-gated: accepts `dry_run` query flag or JSON body.
pub async fn storage_purge_orphans_handler(
    State(state): State<StorageState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
    body: Option<Json<PurgeOrphansRequest>>,
) -> Result<Json<PurgeOrphansResponse>, (StatusCode, Json<serde_json::Value>)> {
    let body_req = body.map(|Json(b)| b);
    let body_pin = body_req
        .as_ref()
        .and_then(|b| b.admin_pin.as_deref().or(b.pin.as_deref()));

    if !AuthService::is_admin_authorized(&state.pool, &headers, body_pin).await {
        return Err((
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "success": false,
                "error": "Unauthorized"
            })),
        ));
    }

    let query_dry_run = query
        .get("dry_run")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("yes"))
        .unwrap_or(false);

    let dry_run = query_dry_run || body_req.as_ref().and_then(|b| b.dry_run).unwrap_or(false);

    let res = StorageService::purge_orphaned_caches(
        &state.pool,
        &state.media_roots,
        &state.cache_dir,
        &state.system_service,
        dry_run,
    )
    .await;

    if !dry_run {
        StorageService::invalidate_audit_cache();
    }

    let ip = AuditService::extract_client_ip(&headers);
    let (actor_type, actor_id) = AuditService::extract_actor(&state.pool, &headers, body_pin).await;
    AuditService::record_event(
        &state.pool,
        actor_type,
        &actor_id,
        "cache_purge",
        Some("cache"),
        None,
        Some(serde_json::json!({
            "dry_run": dry_run,
            "refused": res.refused,
            "freed_bytes": res.freed_bytes,
            "purged_directories": res.purged_dirs.len(),
        })),
        ip.as_deref(),
    )
    .await;

    Ok(Json(PurgeOrphansResponse {
        success: !res.refused,
        result: res,
    }))
}

/// `GET /api/storage/settings`
///
/// Non-gated read of current post-transcode storage retention settings.
pub async fn storage_get_settings_handler(
    State(state): State<StorageState>,
) -> Json<StorageSettingsResponse> {
    let settings = StorageService::get_settings(&state.pool, &state.media_roots).await;
    Json(settings)
}

/// `POST /api/storage/settings`
///
/// Update post-transcode storage retention policy in PostgreSQL `settings` table.
/// Administrator-gated: requires valid `X-Admin-Pin` header or body PIN.
pub async fn storage_post_settings_handler(
    State(state): State<StorageState>,
    headers: HeaderMap,
    body: Option<Json<StorageSettingsUpdateRequest>>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    let body_req = body.map(|Json(b)| b);
    let body_pin = body_req
        .as_ref()
        .and_then(|b| b.admin_pin.as_deref().or(b.pin.as_deref()));

    if !AuthService::is_admin_authorized(&state.pool, &headers, body_pin).await {
        return Err((
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "success": false,
                "error": "Administrator privileges required to change storage policy."
            })),
        ));
    }

    let policy = match body_req.as_ref().and_then(|b| b.retention_policy.clone()) {
        Some(p) => p,
        None => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({
                    "success": false,
                    "error": format!("Invalid retention policy. Allowed: {:?}", ALLOWED_RETENTION_POLICIES)
                })),
            ));
        }
    };

    match StorageService::set_settings(&state.pool, &policy).await {
        Ok(saved_policy) => {
            let ip = AuditService::extract_client_ip(&headers);
            let (actor_type, actor_id) = AuditService::extract_actor(&state.pool, &headers, body_pin).await;
            AuditService::record_event(
                &state.pool,
                actor_type,
                &actor_id,
                "storage_policy_update",
                Some("settings"),
                Some("retention_policy"),
                Some(serde_json::json!({ "policy": saved_policy })),
                ip.as_deref(),
            )
            .await;

            Ok(Json(serde_json::json!({
                "success": true,
                "retention_policy": saved_policy
            })))
        }
        Err(AppError::BadRequest(msg)) => Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "success": false,
                "error": msg
            })),
        )),
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({
                "success": false,
                "error": err.to_string()
            })),
        )),
    }
}

/// `POST /api/storage/archive/{*filename}`
///
/// Move an original media source file to ARCHIVE_DIR if its HLS transcode is complete.
/// Administrator-gated: requires valid `X-Admin-Pin` header.
pub async fn storage_archive_media_handler(
    State(state): State<StorageState>,
    Path(filename): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    if !AuthService::is_admin_authorized(&state.pool, &headers, None).await {
        return Err((
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "success": false,
                "error": "Unauthorized"
            })),
        ));
    }

    match StorageService::archive_media(&state.pool, &filename, &state.media_roots, &state.cache_dir).await {
        Ok(res) => Ok(Json(serde_json::json!({
            "success": true,
            "result": res
        }))),
        Err(AppError::NotFound(msg)) => Err((
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({
                "success": false,
                "error": msg
            })),
        )),
        Err(AppError::BadRequest(msg)) => Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "success": false,
                "result": {
                    "status": "incomplete",
                    "message": msg
                }
            })),
        )),
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({
                "success": false,
                "error": err.to_string()
            })),
        )),
    }
}

/// `DELETE /api/media/{*filename}`
/// `POST /api/media/delete/{*filename}`
///
/// Permanently delete a media item and purge all associated metadata, caches, and streams.
/// Administrator-gated: requires valid `X-Admin-Pin` header or body PIN.
pub async fn storage_delete_media_handler(
    State(state): State<StorageState>,
    Path(filename): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    if !AuthService::is_admin_authorized(&state.pool, &headers, None).await {
        return Err((
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "success": false,
                "error": "Administrator privileges required to delete and purge media."
            })),
        ));
    }

    match StorageService::purge_media(&state.pool, &filename, &state.media_roots, &state.cache_dir).await {
        Ok(res) => {
            let ip = AuditService::extract_client_ip(&headers);
            let (actor_type, actor_id) = AuditService::extract_actor(&state.pool, &headers, None).await;
            AuditService::record_event(
                &state.pool,
                actor_type,
                &actor_id,
                "media_delete",
                Some("media"),
                Some(&filename),
                Some(res.clone()),
                ip.as_deref(),
            )
            .await;

            Ok(Json(res))
        }
        Err(AppError::BadRequest(msg)) => Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "success": false,
                "error": msg
            })),
        )),
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({
                "success": false,
                "error": err.to_string()
            })),
        )),
    }
}
