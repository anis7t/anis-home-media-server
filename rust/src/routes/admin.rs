use crate::error::AppError;
use crate::models::auth::{AdminStatusResponse, AdminVerifyResponse};
use crate::services::auth_service::AuthService;
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::Deserialize;
use sqlx::PgPool;
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
