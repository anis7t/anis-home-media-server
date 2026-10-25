use axum::{response::IntoResponse, Json};
use serde_json::json;

pub async fn health_handler() -> impl IntoResponse {
    Json(json!({
        "status": "healthy",
        "engine": "rust",
        "service": "media-server-api",
        "version": env!("CARGO_PKG_VERSION")
    }))
}
