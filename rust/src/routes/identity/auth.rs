use crate::error::AppError;
use crate::models::auth::{AccountResponse, AllowlistResponse};
use crate::services::audit_service::AuditService;
use crate::services::auth_service::AuthService;
use axum::{
    extract::{Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Redirect, Response},
    Json,
};
use serde::Deserialize;
use sqlx::PgPool;
use std::sync::Arc;

#[derive(Clone)]
pub struct AuthState {
    pub pool: Arc<PgPool>,
}

#[derive(Debug, Deserialize, Default)]
pub struct OAuthStartQuery {
    pub next: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct OAuthCallbackQuery {
    pub code: Option<String>,
    pub state: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct AllowlistPayload {
    pub emails: Option<serde_json::Value>,
}

fn get_host_url(headers: &HeaderMap) -> String {
    // A configured public origin wins over the request headers. The `Host`
    // header is attacker-controlled, and this value becomes the Google OAuth
    // redirect URI - a forged one would send the authorization code to a
    // host of the attacker's choosing.
    if let Some(origin) = crate::config::public_base_url() {
        return origin;
    }
    let host = headers
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("localhost:8001");
    let proto = headers
        .get("X-Forwarded-Proto")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("http");
    format!("{}://{}", proto, host)
}

fn get_redirect_uri(headers: &HeaderMap) -> String {
    if let Ok(uri) = std::env::var("MEDIA_SERVER_GOOGLE_REDIRECT_URI") {
        let trimmed = uri.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    format!("{}/auth/google/callback", get_host_url(headers))
}

/// `GET /api/auth/me`
pub async fn auth_me_handler(
    State(state): State<AuthState>,
    headers: HeaderMap,
) -> Result<Json<AccountResponse>, AppError> {
    let oauth_configured = Some(AuthService::is_oauth_configured());
    if let Some(identity) = AuthService::resolve_session_identity(&state.pool, &headers).await {
        Ok(Json(AccountResponse {
            authenticated: true,
            email: Some(identity.email),
            name: identity.name,
            picture: identity.picture,
            role: Some(identity.role),
            is_admin: Some(identity.is_admin),
            oauth_configured,
        }))
    } else {
        Ok(Json(AccountResponse {
            authenticated: false,
            email: None,
            name: None,
            picture: None,
            role: None,
            is_admin: None,
            oauth_configured,
        }))
    }
}

/// `GET /api/auth/allowlist`
pub async fn get_allowlist_handler(
    State(state): State<AuthState>,
    headers: HeaderMap,
) -> Result<Json<AllowlistResponse>, AppError> {
    // Admin-only, always. The allowlist decides who may sign in; when
    // `MEDIA_SERVER_AUTH` is off this used to be reachable anonymously, so any
    // visitor could rewrite it and lock every real account out. Enforcement is
    // an API-access switch, not an authorization substitute for this surface.
    let is_admin = AuthService::is_admin_authorized(&state.pool, &headers, None).await;
    if !is_admin {
        return Err(AppError::Unauthorized(
            "Authentication required.".to_string(),
        ));
    }

    let resp = AuthService::get_allowlist(&state.pool).await;
    Ok(Json(resp))
}

/// `POST /api/auth/allowlist`
pub async fn post_allowlist_handler(
    State(state): State<AuthState>,
    headers: HeaderMap,
    body: Option<Json<AllowlistPayload>>,
) -> Result<Json<serde_json::Value>, AppError> {
    // Admin-only, always. See `get_allowlist_handler`: this write decides who
    // may sign in, and it must never be reachable anonymously.
    let is_admin = AuthService::is_admin_authorized(&state.pool, &headers, None).await;
    if !is_admin {
        return Err(AppError::Unauthorized(
            "Authentication required.".to_string(),
        ));
    }

    let raw_emails = body.and_then(|Json(b)| b.emails);
    let email_list: Vec<String> = match raw_emails {
        None => Vec::new(),
        Some(serde_json::Value::Array(arr)) => {
            let mut list = Vec::new();
            for item in arr {
                match item {
                    serde_json::Value::String(s) => list.push(s),
                    _ => {
                        return Err(AppError::BadRequest(
                            "'emails' must be a list of strings.".to_string(),
                        ));
                    }
                }
            }
            list
        }
        Some(_) => {
            return Err(AppError::BadRequest(
                "'emails' must be a list of strings.".to_string(),
            ));
        }
    };

    let updated = AuthService::set_allowlist(&state.pool, &email_list).await?;

    let ip = AuditService::extract_client_ip(&headers);
    let (actor_type, actor_id) = AuditService::extract_actor(&state.pool, &headers, None).await;
    AuditService::record_event(
        &state.pool,
        actor_type,
        &actor_id,
        "allowlist_update",
        Some("settings"),
        Some("auth_allowlist"),
        Some(serde_json::json!({
            "emails": email_list,
            "stored": updated.stored,
            "effective_count": updated.effective.len(),
        })),
        ip.as_deref(),
    )
    .await;

    Ok(Json(serde_json::json!({
        "success": true,
        "stored": updated.stored,
        "environment": updated.environment,
        "effective": updated.effective,
    })))
}

/// `POST /api/auth/login-pin`
pub async fn login_pin_handler(
    State(state): State<AuthState>,
    headers: HeaderMap,
    body: Option<Json<crate::models::auth::LoginPinPayload>>,
) -> Result<Response, AppError> {
    let pin = body
        .and_then(|Json(b)| b.pin)
        .unwrap_or_default()
        .trim()
        .to_string();

    let (session_token, user_id, email) = AuthService::login_with_pin(&state.pool, &pin).await?;

    let cookie_val = AuthService::session_cookie(&session_token, &headers);

    let body = serde_json::json!({
        "success": true,
        "user": {
            "id": user_id,
            "email": email,
            "role": "admin",
            "is_admin": true,
        }
    });

    let mut res = (StatusCode::OK, Json(body)).into_response();
    if let Ok(hdr_val) = header::HeaderValue::from_str(&cookie_val) {
        res.headers_mut().insert(header::SET_COOKIE, hdr_val);
    }

    Ok(res)
}

/// `GET /auth/google`
pub async fn google_start_handler(
    State(state): State<AuthState>,
    Query(query): Query<OAuthStartQuery>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    if !AuthService::is_oauth_configured() {
        return Ok(Redirect::temporary("/account?error=oauth_unconfigured").into_response());
    }
    let redirect_uri = get_redirect_uri(&headers);
    let auth_url = AuthService::oauth_start(&state.pool, &redirect_uri, query.next.as_deref()).await?;
    Ok(Redirect::temporary(&auth_url).into_response())
}

/// `GET /auth/google/callback`
pub async fn google_callback_handler(
    State(state): State<AuthState>,
    Query(query): Query<OAuthCallbackQuery>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    if let Some(err) = query.error {
        return Err(AppError::BadRequest(format!("Google returned an error: {}", err)));
    }

    let code = query.code.ok_or_else(|| {
        AppError::BadRequest("Google did not return an authorization code.".to_string())
    })?;
    let oauth_state = query.state.ok_or_else(|| {
        AppError::BadRequest("Sign-in state is missing. Start again from the sign-in link.".to_string())
    })?;

    let (session_token, next_path) = AuthService::oauth_callback(&state.pool, &code, &oauth_state).await?;

    let mut dest = next_path;
    if !dest.starts_with('/') || dest.starts_with("//") {
        dest = "/".to_string();
    }

    let cookie_val = AuthService::session_cookie(&session_token, &headers);

    let mut res = Redirect::temporary(&dest).into_response();
    if let Ok(hdr_val) = header::HeaderValue::from_str(&cookie_val) {
        res.headers_mut().insert(header::SET_COOKIE, hdr_val);
    }

    Ok(res)
}

/// `POST /auth/logout` & `GET /auth/logout`
pub async fn logout_handler(
    State(state): State<AuthState>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let _ = AuthService::logout_session(&state.pool, &headers).await;

    let clear_cookie = AuthService::clear_session_cookie(&headers);
    let mut res = Redirect::temporary("/").into_response();
    if let Ok(hdr_val) = header::HeaderValue::from_str(&clear_cookie) {
        res.headers_mut().insert(header::SET_COOKIE, hdr_val);
    }

    Ok(res)
}

/// `GET /auth/callback/mobile`
///
/// Bridge page served after Google OAuth sign-in completing on a mobile browser / Custom Tab.
/// Extracts the session token from the cookie set by `/auth/google/callback` and immediately
/// deep-links into the Android app via custom scheme `ahms://auth/callback?session_token=<token>`.
pub async fn mobile_oauth_callback_handler(headers: HeaderMap) -> Response {
    let token = headers
        .get(axum::http::header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .and_then(|cookies| {
            for part in cookies.split(';') {
                let mut kv = part.splitn(2, '=');
                if let (Some(k), Some(v)) = (kv.next(), kv.next()) {
                    let key = k.trim();
                    let val = v.trim();
                    if (key == "session_token" || key == "media_session") && !val.is_empty() {
                        return Some(val.to_string());
                    }
                }
            }
            None
        })
        .unwrap_or_default();

    // Sanitize token characters strictly for safe HTML and URL injection
    let clean_token: String = token
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .collect();

    let html = r##"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Anis' Home Media Server - Sign In</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body {
      margin: 0;
      padding: 24px;
      background-color: #05060a;
      color: #ffffff;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      box-sizing: border-box;
      text-align: center;
    }
    .card {
      background: rgba(255, 255, 255, 0.04);
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 24px;
      padding: 32px 24px;
      max-width: 400px;
      width: 100%;
      box-shadow: 0 20px 40px rgba(0, 0, 0, 0.6);
    }
    .btn {
      display: inline-block;
      margin-top: 24px;
      background: #e50914;
      color: #fff;
      font-weight: 700;
      padding: 14px 28px;
      border-radius: 9999px;
      text-decoration: none;
      box-shadow: 0 4px 14px rgba(229, 9, 20, 0.4);
    }
  </style>
</head>
<body>
  <div class="card">
    <div style="font-size: 40px; margin-bottom: 12px;">🍿</div>
    <h1 style="font-size: 20px; margin: 0 0 8px 0;">Signed In Successfully</h1>
    <p style="color: rgba(255, 255, 255, 0.6); font-size: 14px; margin: 0;">Returning to Anis' Home Media Server app...</p>
    <a id="app-btn" class="btn" href="#">Open App</a>
  </div>
  <script>
    (function() {
      var token = "{token}";
      if (!token) {
        var match = document.cookie.match(/session_token=([^;]+)/);
        if (match) token = match[1];
      }
      var targetUri = "ahms://auth/callback?session_token=" + encodeURIComponent(token);
      var btn = document.getElementById("app-btn");
      if (btn) btn.href = targetUri;
      setTimeout(function() {
        window.location.href = targetUri;
      }, 50);
    })();
  </script>
</body>
</html>"##
        .replace("{token}", &clean_token);

    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        html,
    )
        .into_response()
}
