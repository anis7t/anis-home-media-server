use crate::error::AppError;
use crate::models::progress::{SuccessResponse, UpdateProgressRequest};
use crate::services::progress_service::ProgressService;
use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use sqlx::PgPool;

#[derive(Debug, Deserialize)]
pub struct ProgressQuery {
    pub filename: Option<String>,
}

use crate::services::auth_service::AuthService;

fn extract_device_id(headers: &HeaderMap) -> Option<&str> {
    headers
        .get("x-device-id")
        .and_then(|v| v.to_str().ok())
        .or_else(|| {
            headers
                .get("cookie")
                .and_then(|v| v.to_str().ok())
                .and_then(|c| {
                    c.split(';')
                        .map(|s| s.trim())
                        .find(|s| s.starts_with("ms_device_id="))
                        .map(|s| &s["ms_device_id=".len()..])
                })
        })
}

async fn extract_user_id(
    pool: &PgPool,
    headers: &HeaderMap,
    device_id: Option<&str>,
) -> Option<i64> {
    AuthService::resolve_effective_user_id(pool, headers, device_id).await
}

pub async fn get_progress_handler(
    State(pool): State<PgPool>,
    headers: HeaderMap,
    Query(query): Query<ProgressQuery>,
) -> Result<impl IntoResponse, AppError> {
    let filename = query
        .filename
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| AppError::BadRequest("Filename query parameter is required".to_string()))?;

    let device_id = extract_device_id(&headers);
    let user_id = extract_user_id(&pool, &headers, device_id).await;
    let progress = ProgressService::get_progress(&pool, &filename, device_id, user_id).await?;

    Ok(Json(progress))
}

pub async fn post_progress_handler(
    State(pool): State<PgPool>,
    headers: HeaderMap,
    Json(payload): Json<UpdateProgressRequest>,
) -> Result<impl IntoResponse, AppError> {
    let device_id = extract_device_id(&headers);
    let user_id = extract_user_id(&pool, &headers, device_id).await;
    ProgressService::update_progress(&pool, payload, device_id, user_id).await?;

    Ok((StatusCode::OK, Json(SuccessResponse { success: true })))
}
