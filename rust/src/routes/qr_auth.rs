/// QR Device Sign-In Routes
///
/// Implements the two-device handshake for signing in on TVs and browsers
/// without needing to type credentials:
///
/// 1. `POST /api/auth/qr`              — TV creates a pair session, gets QR data
/// 2. `GET  /api/auth/qr/{id}/wait`    — TV waits via SSE; pushed on confirmation
/// 3. `GET  /api/auth/qr/{id}/status`  — TV polls (fallback for SSE-hostile proxies)
/// 4. `POST /api/auth/qr/{id}/confirm` — Phone confirms after Google sign-in
/// 5. `GET  /api/auth/qr/{id}/finalize`— TV fetches this to get the session cookie
use crate::error::AppError;
use crate::services::auth_service::AuthService;
use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use std::sync::Arc;
use tokio::time::Duration;

#[derive(Clone)]
pub struct QrAuthState {
    pub pool: Arc<PgPool>,
}

// ─── Request / Response shapes ───────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct CreateQrResponse {
    pub qr_id: String,
    pub code: String,
    /// HMAC-SHA256 of "qr_id:code" – embedded in QR URL so the phone can skip code entry
    pub sig: String,
    /// Unix timestamp when this session expires (2 minutes from creation)
    pub expires_at: i64,
    /// Full URL to embed in the QR code
    pub qr_url: String,
    /// Human-readable remote login URL (for displaying alongside the QR)
    pub login_url: String,
}

#[derive(Debug, Serialize)]
pub struct QrStatusResponse {
    /// "pending" | "confirmed" | "expired"
    pub status: String,
}

#[derive(Debug, Deserialize)]
pub struct LookupQrPayload {
    pub code: String,
}

#[derive(Debug, Serialize)]
pub struct LookupQrResponse {
    pub qr_id: String,
    pub code: String,
}

#[derive(Debug, Deserialize)]
pub struct ConfirmQrPayload {
    /// The 5-char pair code (required if QR sig was NOT used)
    pub code: Option<String>,
    /// HMAC sig from the QR URL (skips manual code check if valid)
    pub sig: Option<String>,
    /// Friendly name for this device, set by the phone user
    pub device_name: String,
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn cookie_value(headers: &HeaderMap, name: &str) -> Option<String> {
    let raw = headers.get(header::COOKIE)?.to_str().ok()?;
    raw.split(';')
        .filter_map(|pair| pair.trim().split_once('='))
        .find(|(k, _)| k.trim() == name)
        .map(|(_, v)| v.trim().to_string())
}

fn get_base_url(headers: &HeaderMap) -> String {
    let host = headers
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("localhost:8000");
    let proto = headers
        .get("X-Forwarded-Proto")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("https");
    format!("{}://{}", proto, host)
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// `POST /api/auth/qr`
///
/// Creates a new QR pair session. The TV/browser calls this immediately on
/// page load to get the QR data to display.
pub async fn create_pair_session_handler(
    State(state): State<QrAuthState>,
    headers: HeaderMap,
) -> Result<Json<CreateQrResponse>, AppError> {
    let (qr_id, code, sig, expires_at) =
        AuthService::create_pair_session(&state.pool).await?;

    let base = get_base_url(&headers);
    // The QR URL encodes all data needed for a frictionless phone flow
    let qr_url = format!(
        "{}/remotelogin?qr_id={}&code={}&sig={}",
        base,
        urlencoding::encode(&qr_id),
        urlencoding::encode(&code),
        urlencoding::encode(&sig)
    );
    let login_url = format!("{}/remotelogin", base);

    Ok(Json(CreateQrResponse {
        qr_id,
        code,
        sig,
        expires_at,
        qr_url,
        login_url,
    }))
}

/// `POST /api/auth/qr/lookup`
///
/// Resolves a manually entered 5-char code on the phone to an active `qr_id`.
pub async fn qr_lookup_handler(
    State(state): State<QrAuthState>,
    headers: HeaderMap,
    Json(payload): Json<LookupQrPayload>,
) -> Result<Json<LookupQrResponse>, AppError> {
    // Caller must be signed in on phone
    let _ = AuthService::resolve_session_or_token(&state.pool, &headers)
        .await
        .ok_or_else(|| {
            AppError::Unauthorized(
                "You must be signed in on your phone before verifying a pairing code.".to_string(),
            )
        })?;

    let code = payload.code.trim().to_uppercase();
    if code.len() != 5 {
        return Err(AppError::BadRequest(
            "Pairing code must be 5 characters.".to_string(),
        ));
    }

    let qr_id = AuthService::find_pair_session_by_code(&state.pool, &code)
        .await?
        .ok_or_else(|| {
            AppError::NotFound(
                "Pairing code not found or expired. Please check your TV screen.".to_string(),
            )
        })?;

    Ok(Json(LookupQrResponse { qr_id, code }))
}

/// `GET /api/auth/qr/{id}/wait`
///
/// Server-Sent Events stream. The TV/browser keeps this connection open.
/// Every 3 seconds the server sends `data: pending\n\n`.
/// When the phone confirms, it sends `data: confirmed\n\n` and closes.
/// After 130 seconds (just past 2-min TTL), it sends `data: expired\n\n`.
pub async fn qr_wait_handler(
    Path(qr_id): Path<String>,
    State(state): State<QrAuthState>,
) -> impl IntoResponse {
    use axum::body::Body;
    use tokio::sync::mpsc;

    // 16-frame buffer — we only send one frame per 3s tick so this is very generous
    let (tx, rx) = mpsc::channel::<String>(16);

    // Spawn a background task that polls the DB and sends SSE frames
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(3));
        let mut elapsed = 0u32;
        const MAX_WAIT_SECS: u32 = 130;

        loop {
            ticker.tick().await;
            elapsed += 3;

            let frame = match AuthService::get_pair_session_status(&state.pool, &qr_id).await {
                Ok(Some((true, _, _))) => "data: confirmed\n\n".to_string(),
                Ok(None) | Err(_) => "data: expired\n\n".to_string(),
                Ok(Some((false, _, _))) => {
                    if elapsed >= MAX_WAIT_SECS {
                        "data: expired\n\n".to_string()
                    } else {
                        "data: pending\n\n".to_string()
                    }
                }
            };

            let is_terminal = frame.contains("confirmed") || frame.contains("expired");
            // If the receiver is gone (client disconnected), stop polling
            if tx.send(frame).await.is_err() {
                break;
            }
            if is_terminal || elapsed >= MAX_WAIT_SECS {
                break;
            }
        }
    });

    // Convert the mpsc receiver into a byte stream for the HTTP response body
    let byte_stream = futures_util::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|frame| {
            let bytes = axum::body::Bytes::from(frame.into_bytes());
            (Ok::<_, std::convert::Infallible>(bytes), rx)
        })
    });

    axum::response::Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .header("X-Accel-Buffering", "no") // tell reverse proxies not to buffer SSE
        .body(Body::from_stream(byte_stream))
        .expect("SSE response is valid")
}

/// `GET /api/auth/qr/{id}/status`
///
/// Simple poll endpoint — fallback for environments where SSE is not reliable.
pub async fn qr_status_handler(
    Path(qr_id): Path<String>,
    State(state): State<QrAuthState>,
) -> Result<Json<QrStatusResponse>, AppError> {
    let status = match AuthService::get_pair_session_status(&state.pool, &qr_id).await? {
        Some((true, _, _)) => "confirmed",
        Some((false, _, _)) => "pending",
        None => "expired",
    };
    Ok(Json(QrStatusResponse {
        status: status.to_string(),
    }))
}

/// `POST /api/auth/qr/{id}/confirm`
///
/// Called by the phone after the user is authenticated (Google session cookie
/// must be present). Validates the pair code or HMAC sig, mints a session for
/// the TV, and marks the pair session as confirmed so the SSE stream fires.
pub async fn qr_confirm_handler(
    Path(qr_id): Path<String>,
    State(state): State<QrAuthState>,
    headers: HeaderMap,
    body: Option<Json<ConfirmQrPayload>>,
) -> Result<Json<serde_json::Value>, AppError> {
    // The phone must be signed in
    let identity = AuthService::resolve_session_or_token(&state.pool, &headers)
        .await
        .ok_or_else(|| {
            AppError::Unauthorized(
                "You must be signed in on your phone to complete this pairing.".to_string(),
            )
        })?;

    let payload = body
        .map(|Json(b)| b)
        .ok_or_else(|| AppError::BadRequest("Request body required.".to_string()))?;

    let device_name = payload.device_name.trim().to_string();
    if device_name.is_empty() {
        return Err(AppError::BadRequest(
            "Please enter a friendly name for this device (e.g. 'Living room TV').".to_string(),
        ));
    }
    if device_name.len() > 60 {
        return Err(AppError::BadRequest(
            "Device name must be 60 characters or fewer.".to_string(),
        ));
    }

    let submitted_code = payload.code.as_deref().unwrap_or("");
    let submitted_sig = payload.sig.as_deref();

    AuthService::confirm_pair_session(
        &state.pool,
        &qr_id,
        submitted_code,
        submitted_sig,
        identity.user_id,
        &device_name,
    )
    .await?;

    Ok(Json(serde_json::json!({
        "success": true,
        "message": "Device paired successfully. Your TV will sign in automatically."
    })))
}

/// `GET /api/auth/qr/{id}/finalize`
///
/// Called by the TV/browser after receiving the SSE `confirmed` event.
/// Sets the session cookie and redirects to `/`.
pub async fn qr_finalize_handler(
    Path(qr_id): Path<String>,
    State(state): State<QrAuthState>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let status = AuthService::get_pair_session_status(&state.pool, &qr_id).await?;

    let (session_id, device_name) = match status {
        Some((true, Some(sid), dev_name)) => (sid, dev_name),
        Some((true, None, _)) => {
            return Err(AppError::Internal(
                "Pair session confirmed but no session token found.".to_string(),
            ))
        }
        Some((false, _, _)) => {
            return Err(AppError::BadRequest(
                "Pair session not yet confirmed. Please complete the pairing on your phone.".to_string(),
            ))
        }
        None => {
            return Err(AppError::BadRequest(
                "Pair session expired. Please start again.".to_string(),
            ))
        }
    };

    // If TV has a device_id cookie or header and we have a friendly device name, record it in `devices`
    if let Some(dev_name) = device_name {
        if let Some(dev_id) = cookie_value(&headers, "ms_device_id")
            .or_else(|| headers.get("x-device-id").and_then(|v| v.to_str().ok()).map(|s| s.to_string()))
        {
            let _ = sqlx::query("UPDATE devices SET custom_name = $1 WHERE device_id = $2")
                .bind(&dev_name)
                .bind(&dev_id)
                .execute(&*state.pool)
                .await;
        }
    }

    let cookie_val = format!(
        "session_token={}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000",
        session_id
    );

    let mut res = axum::response::Redirect::temporary("/").into_response();
    if let Ok(hdr_val) = header::HeaderValue::from_str(&cookie_val) {
        res.headers_mut().insert(header::SET_COOKIE, hdr_val);
    }

    Ok(res)
}
