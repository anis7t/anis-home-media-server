use crate::error::AppError;
use crate::models::audit::{AuditLogQuery, AuditLogResponse};
use crate::models::auth::{AdminStatusResponse, AdminVerifyResponse};
use crate::services::audit_service::AuditService;
use crate::services::auth_service::AuthService;
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, Row};
use std::sync::Arc;

fn extract_client_ip(headers: &HeaderMap) -> Option<String> {
    AuditService::extract_client_ip(headers)
}

async fn extract_actor(pool: &PgPool, headers: &HeaderMap) -> (&'static str, String) {
    AuditService::extract_actor(pool, headers, None).await
}

#[derive(Clone)]
pub struct AdminState {
    pub pool: Arc<PgPool>,
}

#[derive(Debug, Deserialize, Default)]
pub struct AdminVerifyPayload {
    pub pin: Option<serde_json::Value>,
    pub admin_pin: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize, Default)]
pub struct AdminPinPayload {
    pub new_pin: Option<serde_json::Value>,
    pub current_pin: Option<serde_json::Value>,
}

/// One account in the Phase 3 oversight list. `google_sub` is deliberately
/// absent: it is an identity key the UI never needs to see.
#[derive(Debug, Serialize)]
pub struct AdminUserSummary {
    pub id: i64,
    pub email: String,
    pub name: Option<String>,
    pub role: String,
    pub created_at: String,
    pub last_login_at: Option<String>,
    pub device_count: i64,
    pub history_count: i64,
}

#[derive(Debug, Serialize)]
pub struct AdminUsersResponse {
    pub users: Vec<AdminUserSummary>,
}

/// `POST /api/admin/devices/assign` — an explicit human ownership change, and
/// the one sanctioned exception to "claim once, never reassign".
///
/// `user_id` must distinguish three cases: a number (assign), an explicit
/// `null` (unassign) and a **missing key** (a 400 — the caller did not say what
/// to do). `Option<i64>` collapses the last two into `None`, so the field uses
/// the double-option form with the deserializer below.
#[derive(Debug, Deserialize)]
pub struct AdminAssignDevicePayload {
    pub device_id: Option<String>,
    #[serde(default, deserialize_with = "deserialize_explicit_nullable")]
    pub user_id: Option<Option<i64>>,
}

/// Maps a present `null` to `Some(None)`, a present number to `Some(Some(n))`,
/// and leaves an absent key to `#[serde(default)]` (`None`).
fn deserialize_explicit_nullable<'de, D>(deserializer: D) -> Result<Option<Option<i64>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<i64>::deserialize(deserializer).map(Some)
}

/// `POST /api/admin/devices/history/delete`. Naming `filename` deletes exactly
/// that entry; omitting it clears the device's whole history.
#[derive(Debug, Deserialize)]
pub struct AdminDeleteHistoryPayload {
    pub device_id: Option<String>,
    pub filename: Option<String>,
}

fn extract_pin_str(v: Option<&serde_json::Value>) -> Option<String> {
    match v {
        Some(serde_json::Value::String(s)) => Some(s.trim().to_string()),
        Some(serde_json::Value::Number(n)) => Some(n.to_string()),
        _ => None,
    }
}

/// `GET /api/admin/status`
pub async fn admin_status_handler(
    State(state): State<AdminState>,
    headers: HeaderMap,
) -> Result<Json<AdminStatusResponse>, AppError> {
    let status = AuthService::get_admin_status(&state.pool, &headers).await;
    Ok(Json(status))
}

/// `GET /api/admin/users`
///
/// The account list behind the Phase 3 oversight view: who exists, what role
/// they hold, and how many devices / watch-history rows each account owns.
/// Admin-gated like every other `/api/admin/*` route (PIN **or** admin
/// session), and a viewer gets a 403 rather than an empty list.
pub async fn admin_users_handler(
    State(state): State<AdminState>,
    headers: HeaderMap,
) -> Result<Json<AdminUsersResponse>, AppError> {
    if !AuthService::is_admin_authorized(&state.pool, &headers, None).await {
        return Err(AppError::Forbidden(
            "Admin authorization required".to_string(),
        ));
    }

    let rows = sqlx::query(
        r#"
        SELECT
            u.id,
            u.email,
            u.name,
            u.role,
            u.created_at,
            u.last_login_at,
            COALESCE(d.device_count, 0)::BIGINT  AS device_count,
            COALESCE(h.history_count, 0)::BIGINT AS history_count
        FROM users u
        LEFT JOIN (
            SELECT user_id, COUNT(*) AS device_count
            FROM devices
            WHERE user_id IS NOT NULL
            GROUP BY user_id
        ) d ON d.user_id = u.id
        LEFT JOIN (
            SELECT dev.user_id, COUNT(*) AS history_count
            FROM device_watch_history h
            JOIN devices dev ON dev.device_id = h.device_id
            WHERE dev.user_id IS NOT NULL
            GROUP BY dev.user_id
        ) h ON h.user_id = u.id
        ORDER BY u.created_at ASC, u.id ASC
        "#,
    )
    .fetch_all(state.pool.as_ref())
    .await?;

    let users = rows
        .iter()
        .map(|r| AdminUserSummary {
            id: r.try_get("id").unwrap_or_default(),
            email: r.try_get("email").unwrap_or_default(),
            name: r.try_get("name").ok().flatten(),
            role: r.try_get("role").unwrap_or_else(|_| "viewer".to_string()),
            created_at: r
                .try_get::<Option<DateTime<Utc>>, _>("created_at")
                .ok()
                .flatten()
                .map(crate::services::device_service::format_db_timestamp)
                .unwrap_or_default(),
            last_login_at: r
                .try_get::<Option<DateTime<Utc>>, _>("last_login_at")
                .ok()
                .flatten()
                .map(crate::services::device_service::format_db_timestamp),
            device_count: r.try_get("device_count").unwrap_or(0),
            history_count: r.try_get("history_count").unwrap_or(0),
        })
        .collect();

    Ok(Json(AdminUsersResponse { users }))
}

/// `POST /api/admin/verify`
pub async fn admin_verify_handler(
    State(state): State<AdminState>,
    headers: HeaderMap,
    body: Option<Json<AdminVerifyPayload>>,
) -> (StatusCode, Json<AdminVerifyResponse>) {
    let mut candidate_pin = None;
    if let Some(Json(payload)) = body {
        candidate_pin = extract_pin_str(payload.pin.as_ref())
            .or_else(|| extract_pin_str(payload.admin_pin.as_ref()));
    }

    let resp = AuthService::verify_admin_pin(&state.pool, &headers, candidate_pin.as_deref()).await;
    if resp.success {
        (StatusCode::OK, Json(resp))
    } else {
        (StatusCode::UNAUTHORIZED, Json(resp))
    }
}

/// `POST /api/admin/pin`
pub async fn admin_pin_handler(
    State(state): State<AdminState>,
    headers: HeaderMap,
    body: Option<Json<AdminPinPayload>>,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    let (new_pin, current_pin) = match body {
        Some(Json(b)) => (
            extract_pin_str(b.new_pin.as_ref()).unwrap_or_default(),
            extract_pin_str(b.current_pin.as_ref()),
        ),
        None => (String::new(), None),
    };

    AuthService::update_admin_pin(&state.pool, &headers, current_pin.as_deref(), &new_pin).await?;

    let ip = extract_client_ip(&headers);
    let (actor_type, actor_id) = extract_actor(&state.pool, &headers).await;
    AuditService::record_event(
        &state.pool,
        actor_type,
        &actor_id,
        "pin_change",
        Some("settings"),
        Some("admin_pin"),
        None,
        ip.as_deref(),
    )
    .await;

    Ok((StatusCode::OK, Json(serde_json::json!({ "success": true }))))
}

/// `POST /api/admin/devices/assign`
///
/// Sets or clears `devices.user_id`. Admin-gated (PIN **or** admin session);
/// a viewer gets a 403 and no state change. The automatic claim in
/// `DeviceService::claim_device_for_user` remains `WHERE user_id IS NULL` —
/// this route is the explicit, human exception, and the device's watch history
/// moves with the device because ownership is what scopes it.
pub async fn admin_assign_device_handler(
    State(state): State<AdminState>,
    headers: HeaderMap,
    Json(payload): Json<AdminAssignDevicePayload>,
) -> Result<Json<serde_json::Value>, AppError> {
    if !AuthService::is_admin_authorized(&state.pool, &headers, None).await {
        return Err(AppError::Forbidden(
            "Admin authorization required".to_string(),
        ));
    }

    let device_id = payload.device_id.unwrap_or_default().trim().to_string();
    if device_id.is_empty() {
        return Err(AppError::BadRequest("device_id is required".to_string()));
    }

    let device_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE device_id = $1")
        .bind(&device_id)
        .fetch_one(state.pool.as_ref())
        .await?;
    if device_count == 0 {
        return Err(AppError::NotFound(format!("Unknown device: {}", device_id)));
    }

    let target_user = match payload.user_id {
        None => {
            return Err(AppError::BadRequest(
                "user_id is required; send null to unassign".to_string(),
            ))
        }
        Some(id) => id,
    };

    if let Some(uid) = target_user {
        let user_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE id = $1")
            .bind(uid)
            .fetch_one(state.pool.as_ref())
            .await?;
        if user_count == 0 {
            return Err(AppError::NotFound(format!("Unknown user: {}", uid)));
        }
    }

    sqlx::query("UPDATE devices SET user_id = $1 WHERE device_id = $2")
        .bind(target_user)
        .bind(&device_id)
        .execute(state.pool.as_ref())
        .await?;

    let ip = extract_client_ip(&headers);
    let (actor_type, actor_id) = extract_actor(&state.pool, &headers).await;
    AuditService::record_event(
        &state.pool,
        actor_type,
        &actor_id,
        "device_assign",
        Some("device"),
        Some(&device_id),
        Some(serde_json::json!({ "assigned_user_id": target_user })),
        ip.as_deref(),
    )
    .await;

    Ok(Json(serde_json::json!({
        "success": true,
        "device_id": device_id,
        "user_id": target_user,
    })))
}

/// `POST /api/admin/devices/history/delete`
///
/// Deletes one `device_watch_history` row when `filename` is given, or every
/// row for the device when it is omitted. Only history is touched: no media
/// file is read, moved or deleted. Clearing an already-empty device succeeds
/// with `deleted: 0` (idempotent); naming an entry that does not exist is a
/// 404 so a typo is visible rather than silently successful.
pub async fn admin_delete_device_history_handler(
    State(state): State<AdminState>,
    headers: HeaderMap,
    Json(payload): Json<AdminDeleteHistoryPayload>,
) -> Result<Json<serde_json::Value>, AppError> {
    if !AuthService::is_admin_authorized(&state.pool, &headers, None).await {
        return Err(AppError::Forbidden(
            "Admin authorization required".to_string(),
        ));
    }

    let device_id = payload.device_id.unwrap_or_default().trim().to_string();
    if device_id.is_empty() {
        return Err(AppError::BadRequest("device_id is required".to_string()));
    }

    let device_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE device_id = $1")
        .bind(&device_id)
        .fetch_one(state.pool.as_ref())
        .await?;
    if device_count == 0 {
        return Err(AppError::NotFound(format!("Unknown device: {}", device_id)));
    }

    let filename = payload
        .filename
        .map(|f| f.trim().to_string())
        .filter(|f| !f.is_empty());

    let deleted = match filename {
        Some(ref f) => {
            let result = sqlx::query(
                "DELETE FROM device_watch_history WHERE device_id = $1 AND filename = $2",
            )
            .bind(&device_id)
            .bind(f)
            .execute(state.pool.as_ref())
            .await?;
            if result.rows_affected() == 0 {
                return Err(AppError::NotFound(
                    "No watch-history entry matched that device and filename".to_string(),
                ));
            }
            result.rows_affected()
        }
        None => sqlx::query("DELETE FROM device_watch_history WHERE device_id = $1")
            .bind(&device_id)
            .execute(state.pool.as_ref())
            .await?
            .rows_affected(),
    };

    let ip = extract_client_ip(&headers);
    let (actor_type, actor_id) = extract_actor(&state.pool, &headers).await;
    AuditService::record_event(
        &state.pool,
        actor_type,
        &actor_id,
        "device_history_delete",
        Some("device"),
        Some(&device_id),
        Some(serde_json::json!({ "filename": filename, "deleted": deleted })),
        ip.as_deref(),
    )
    .await;

    Ok(Json(serde_json::json!({
        "success": true,
        "device_id": device_id,
        "deleted": deleted,
    })))
}

/// `GET /api/admin/audit-logs`
pub async fn admin_audit_logs_handler(
    State(state): State<AdminState>,
    headers: HeaderMap,
    axum::extract::Query(query): axum::extract::Query<AuditLogQuery>,
) -> Result<Json<AuditLogResponse>, AppError> {
    if !AuthService::is_admin_authorized(&state.pool, &headers, None).await {
        return Err(AppError::Unauthorized(
            "Admin authorization required".to_string(),
        ));
    }

    let resp = AuditService::list_logs(
        state.pool.as_ref(),
        query.limit,
        query.offset,
        query.action.as_deref(),
    )
    .await
    .map_err(|e| AppError::Internal(format!("Failed to retrieve audit logs: {}", e)))?;

    Ok(Json(resp))
}
