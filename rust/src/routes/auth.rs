use crate::error::AppError;
use crate::models::auth::{AccountResponse, AllowlistResponse, MintedToken};
use crate::services::auth_service::AuthService;
use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{Html, IntoResponse, Redirect, Response},
    Json,
};
use serde::Deserialize;
use sqlx::{PgPool, Row};
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

#[derive(Debug, Deserialize, Default)]
pub struct MintTokenPayload {
    pub label: Option<String>,
    pub validity_days: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize, Default)]
pub struct PairPayload {
    pub token: Option<String>,
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

fn is_enforcement_enabled() -> bool {
    std::env::var("MEDIA_SERVER_AUTH")
        .map(|v| {
            let t = v.trim().to_lowercase();
            t == "1" || t == "true"
        })
        .unwrap_or(false)
}

/// `GET /api/auth/me`
pub async fn auth_me_handler(
    State(state): State<AuthState>,
    headers: HeaderMap,
) -> Result<Json<AccountResponse>, AppError> {
    let oauth_configured = Some(AuthService::is_oauth_configured());
    if let Some(identity) = AuthService::resolve_session_or_token(&state.pool, &headers).await {
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
    Ok(Json(serde_json::json!({
        "success": true,
        "stored": updated.stored,
        "environment": updated.environment,
        "effective": updated.effective,
    })))
}

/// `GET /api/auth/tokens`
pub async fn get_tokens_handler(
    State(state): State<AuthState>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, AppError> {
    // Bearer tokens cannot manage or mint tokens
    if let Some(auth_hdr) = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()) {
        if auth_hdr.trim().to_lowercase().starts_with("bearer ") {
            return Err(AppError::Forbidden(
                "Device tokens cannot manage or mint further tokens.".to_string(),
            ));
        }
    }

    let identity = AuthService::resolve_session_or_token(&state.pool, &headers).await;
    let pin_authed = AuthService::is_admin_authorized(&state.pool, &headers, None).await;

    if is_enforcement_enabled() && identity.is_none() && !pin_authed {
        return Err(AppError::Unauthorized("Authentication required.".to_string()));
    }
    if identity.is_none() && !pin_authed {
        return Err(AppError::Forbidden(
            "Sign in or provide the Admin PIN to manage device tokens.".to_string(),
        ));
    }

    let is_admin = pin_authed || identity.as_ref().map(|i| i.is_admin).unwrap_or(false);
    let user_id_filter = if is_admin {
        None
    } else {
        identity.map(|i| i.user_id)
    };

    let tokens = AuthService::list_tokens(&state.pool, user_id_filter).await?;
    Ok(Json(serde_json::json!({ "tokens": tokens })))
}

/// `POST /api/auth/tokens`
pub async fn post_tokens_handler(
    State(state): State<AuthState>,
    headers: HeaderMap,
    body: Option<Json<MintTokenPayload>>,
) -> Result<(StatusCode, Json<MintedToken>), AppError> {
    // Bearer tokens cannot manage or mint tokens
    if let Some(auth_hdr) = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()) {
        if auth_hdr.trim().to_lowercase().starts_with("bearer ") {
            return Err(AppError::Forbidden(
                "Device tokens cannot manage or mint further tokens.".to_string(),
            ));
        }
    }

    let identity = AuthService::resolve_session_or_token(&state.pool, &headers).await;
    let pin_authed = AuthService::is_admin_authorized(&state.pool, &headers, None).await;

    if is_enforcement_enabled() && identity.is_none() && !pin_authed {
        return Err(AppError::Unauthorized("Authentication required.".to_string()));
    }
    if identity.is_none() && !pin_authed {
        return Err(AppError::Forbidden(
            "Sign in or provide the Admin PIN to manage device tokens.".to_string(),
        ));
    }

    // Determine target user id
    let user_id = if let Some(id) = identity {
        id.user_id
    } else {
        // PIN authenticated: find or create admin user row
        let admin_row = sqlx::query("SELECT id FROM users WHERE role = 'admin' ORDER BY id ASC")
            .fetch_optional(&*state.pool)
            .await?;
        match admin_row {
            Some(r) => r.get("id"),
            None => {
                let inserted = sqlx::query(
                    r#"
                    INSERT INTO users (google_sub, email, name, role, created_at)
                    VALUES ('admin_pin', 'admin@local', 'Administrator', 'admin', CURRENT_TIMESTAMP)
                    ON CONFLICT (google_sub) DO UPDATE SET role = 'admin'
                    RETURNING id
                    "#,
                )
                .fetch_one(&*state.pool)
                .await?;
                inserted.get("id")
            }
        }
    };

    let payload = body.map(|Json(b)| b).unwrap_or_default();
    let label = payload.label.unwrap_or_default().trim().to_string();
    if label.is_empty() {
        return Err(AppError::BadRequest(
            "A label is required so the token can be identified later.".to_string(),
        ));
    }

    let validity_days: Option<i64> = match payload.validity_days {
        None => Some(365),
        Some(serde_json::Value::Number(n)) => {
            let v = n.as_i64().unwrap_or(0);
            if v <= 0 {
                return Err(AppError::BadRequest(
                    "validity_days must be a positive integer or null.".to_string(),
                ));
            }
            Some(v)
        }
        Some(serde_json::Value::Null) => None,
        Some(_) => {
            return Err(AppError::BadRequest(
                "validity_days must be a positive integer or null.".to_string(),
            ));
        }
    };

    let host_url = get_host_url(&headers);
    let minted = AuthService::create_token(&state.pool, user_id, &label, validity_days, &host_url).await?;

    Ok((StatusCode::CREATED, Json(minted)))
}

/// `DELETE /api/auth/tokens/{id}`
pub async fn delete_token_handler(
    State(state): State<AuthState>,
    Path(token_id): Path<i64>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, AppError> {
    // Bearer tokens cannot manage or revoke tokens
    if let Some(auth_hdr) = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()) {
        if auth_hdr.trim().to_lowercase().starts_with("bearer ") {
            return Err(AppError::Forbidden(
                "Device tokens cannot manage or revoke tokens.".to_string(),
            ));
        }
    }

    let identity = AuthService::resolve_session_or_token(&state.pool, &headers).await;
    let pin_authed = AuthService::is_admin_authorized(&state.pool, &headers, None).await;

    if is_enforcement_enabled() && identity.is_none() && !pin_authed {
        return Err(AppError::Unauthorized("Authentication required.".to_string()));
    }
    if identity.is_none() && !pin_authed {
        return Err(AppError::Forbidden(
            "Sign in or provide the Admin PIN to manage device tokens.".to_string(),
        ));
    }

    let is_admin = pin_authed || identity.as_ref().map(|i| i.is_admin).unwrap_or(false);
    let caller_user_id = identity.map(|i| i.user_id);

    AuthService::revoke_token(&state.pool, token_id, caller_user_id, is_admin).await?;

    Ok(Json(serde_json::json!({ "revoked": token_id })))
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

/// `GET /auth/pair`
pub async fn pair_page_handler() -> Html<&'static str> {
    Html(
        r#"<!doctype html><meta charset=utf-8>
<title>Pair this device</title>
<body style='font-family:system-ui;background:#090b10;color:#e8eaf0;padding:2rem'>
<h1>Pairing this device</h1>
<p id='msg'>Completing&hellip;</p>
<form id='f' method='post' action='/auth/pair'></form>
<script>
const t=location.hash.slice(1);
if(!t){document.getElementById('msg').textContent='No pairing token in the link.';}
else{const f=document.getElementById('f');
const i=document.createElement('input');i.name='token';i.value=decodeURIComponent(t);
f.appendChild(i);f.submit();}
</script></body>"#
    )
}

/// `POST /auth/pair`
pub async fn pair_submit_handler(
    State(state): State<AuthState>,
    headers: HeaderMap,
    axum::extract::Form(form): axum::extract::Form<PairPayload>,
) -> Result<Response, AppError> {
    let token = form.token.unwrap_or_default().trim().to_string();
    if token.is_empty() {
        return Err(AppError::Unauthorized(
            "That pairing token is not valid.".to_string(),
        ));
    }

    let session_token = AuthService::pair_token(&state.pool, &token).await?;

    let cookie_val = AuthService::session_cookie(&session_token, &headers);

    let mut res = Redirect::temporary("/").into_response();
    if let Ok(hdr_val) = header::HeaderValue::from_str(&cookie_val) {
        res.headers_mut().insert(header::SET_COOKIE, hdr_val);
    }

    Ok(res)
}
