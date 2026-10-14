use crate::services::system_service::SystemService;
use axum::{extract::State, response::IntoResponse, Json};

pub async fn system_status_handler(
    State(system_service): State<SystemService>,
) -> impl IntoResponse {
    let telemetry = system_service.get_telemetry();
    Json(telemetry)
}
