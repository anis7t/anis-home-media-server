use crate::error::AppError;
use crate::services::range_service::RangeService;
use axum::{
    body::Body,
    extract::{Query, State},
    http::{header, HeaderMap, HeaderValue, Method, Response},
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Clone)]
pub struct AppDistState {
    pub base_dir: Arc<PathBuf>,
}

#[derive(Debug, Deserialize)]
pub struct ChannelQuery {
    pub channel: Option<String>,
}

fn sanitize_channel(query_channel: Option<&str>) -> Result<String, AppError> {
    let c = query_channel.unwrap_or("production").trim().to_lowercase();
    let effective = if c.is_empty() {
        "production".to_string()
    } else {
        c
    };

    if effective != "production" && effective != "developer" {
        return Err(AppError::BadRequest(
            "Invalid channel. Must be 'production' or 'developer'.".to_string(),
        ));
    }
    Ok(effective)
}

fn resolve_updates_dir(base_dir: &Path) -> PathBuf {
    let direct = base_dir.join("updates");
    if direct.is_dir() {
        return direct;
    }
    if let Some(parent) = base_dir.parent() {
        let parent_updates = parent.join("updates");
        if parent_updates.is_dir() {
            return parent_updates;
        }
    }
    let fallback = PathBuf::from("E:\\MediaServer\\updates");
    if fallback.is_dir() {
        return fallback;
    }
    direct
}

/// `GET /api/app/update?channel=production`
pub async fn app_update_handler(
    State(state): State<AppDistState>,
    Query(query): Query<ChannelQuery>,
) -> Result<Response<Body>, AppError> {
    let channel = sanitize_channel(query.channel.as_deref())?;
    let updates_dir = resolve_updates_dir(&state.base_dir);
    let manifest_file = updates_dir.join(&channel).join("manifest.json");

    if !manifest_file.is_file() {
        return Err(AppError::NotFound(format!(
            "No update manifest found for channel '{}'.",
            channel
        )));
    }

    let content = tokio::fs::read_to_string(&manifest_file)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to read update manifest: {}", e)))?;

    let parsed: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| AppError::Internal(format!("Malformed update manifest: {}", e)))?;

    let mut res = Json(parsed).into_response();
    let h = res.headers_mut();
    h.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-cache, no-store, must-revalidate"),
    );
    h.insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
    Ok(res)
}

/// `GET /api/app/download?channel=production`
pub async fn app_download_handler(
    State(state): State<AppDistState>,
    Query(query): Query<ChannelQuery>,
    headers: HeaderMap,
    method: Method,
) -> Result<Response<Body>, AppError> {
    let channel = sanitize_channel(query.channel.as_deref())?;
    let updates_dir = resolve_updates_dir(&state.base_dir);
    let apk_file = updates_dir.join(&channel).join("media-server-client.apk");

    if !apk_file.is_file() {
        return Err(AppError::NotFound(format!(
            "APK artifact not found for channel '{}'.",
            channel
        )));
    }

    let mut res = RangeService::stream_file(apk_file, headers, method).await?;
    let h = res.headers_mut();
    h.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/vnd.android.package-archive"),
    );
    let filename = format!("media-server-{}.apk", channel);
    if let Ok(disp) = HeaderValue::from_str(&format!("attachment; filename=\"{}\"", filename)) {
        h.insert(header::CONTENT_DISPOSITION, disp);
    }

    Ok(res)
}
