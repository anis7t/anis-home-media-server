use crate::error::AppError;
use crate::models::auth::{AdminStatusResponse, AdminVerifyResponse};
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
            role: r
                .try_get("role")
                .unwrap_or_else(|_| "viewer".to_string()),
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

    AuthService::update_admin_pin(
        &state.pool,
        &headers,
        current_pin.as_deref(),
        &new_pin,
    )
    .await?;

    Ok((StatusCode::OK, Json(serde_json::json!({ "success": true }))))
}
