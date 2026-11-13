//! Deterministic OAuth provider used only by the feature-gated Phase 0 test image.
//!
//! The API still runs its real OAuth start and callback code. This service
//! accepts only the disposable test client credentials, requires the PKCE
//! verifier, returns deterministic provider claims, and emits no request data
//! to logs. It must never be built into or deployed with the normal API image.

use axum::extract::{Form, Query};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Deserialize)]
struct TokenRequest {
    grant_type: String,
    code: String,
    client_id: String,
    client_secret: String,
    code_verifier: String,
}

#[derive(Debug, Deserialize)]
struct TokenInfoQuery {
    id_token: String,
}

async fn health() -> &'static str {
    "ok"
}

async fn authorization_endpoint() -> &'static str {
    "Phase 0 OAuth mock. The test harness calls the API callback directly."
}

async fn exchange_code(
    Form(request): Form<TokenRequest>,
) -> Result<Json<Value>, (StatusCode, &'static str)> {
    let expected_client_id = std::env::var("PHASE0_MOCK_CLIENT_ID").unwrap_or_default();
    let expected_client_secret = std::env::var("PHASE0_MOCK_CLIENT_SECRET").unwrap_or_default();

    if expected_client_id.is_empty() || expected_client_secret.is_empty() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "mock client is not configured",
        ));
    }
    if request.client_id != expected_client_id || request.client_secret != expected_client_secret {
        return Err((StatusCode::UNAUTHORIZED, "invalid mock client"));
    }
    if request.grant_type != "authorization_code" || request.code_verifier.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "invalid authorization-code exchange",
        ));
    }

    let id_token = match request.code.as_str() {
        "phase0-admin-code" => "phase0-admin-id-token",
        "phase0-viewer-code" => "phase0-viewer-id-token",
        "phase0-denied-code" => "phase0-denied-id-token",
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                "unknown disposable authorization code",
            ))
        }
    };

    Ok(Json(json!({
        "id_token": id_token,
        "token_type": "Bearer",
        "expires_in": 3600
    })))
}

async fn token_info(
    Query(query): Query<TokenInfoQuery>,
) -> Result<Json<Value>, (StatusCode, &'static str)> {
    let (sub, email, name) = match query.id_token.as_str() {
        "phase0-admin-id-token" => (
            "phase0-admin-subject",
            "phase0-admin@example.test",
            "Phase 0 Admin",
        ),
        "phase0-viewer-id-token" => (
            "phase0-viewer-subject",
            "phase0-viewer@example.test",
            "Phase 0 Viewer",
        ),
        "phase0-denied-id-token" => (
            "phase0-denied-subject",
            "phase0-denied@example.test",
            "Phase 0 Denied",
        ),
        _ => return Err((StatusCode::UNAUTHORIZED, "invalid mock ID token")),
    };

    let aud = std::env::var("PHASE0_MOCK_CLIENT_ID").unwrap_or_default();
    if aud.is_empty() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "mock client is not configured",
        ));
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    Ok(Json(json!({
        "iss": "https://accounts.google.com",
        "aud": aud,
        "sub": sub,
        "email": email,
        "email_verified": true,
        "name": name,
        "iat": now,
        "exp": now + 3600
    })))
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let app = Router::new()
        .route("/health", get(health))
        .route("/o/oauth2/v2/auth", get(authorization_endpoint))
        .route("/token", post(exchange_code))
        .route("/tokeninfo", get(token_info));
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    axum::serve(listener, app).await?;
    Ok(())
}
