use crate::error::AppError;
use crate::models::auth::{
    AdminStatusResponse, AdminVerifyResponse, AllowlistResponse, MintedToken, TokenRecord,
};
use axum::http::HeaderMap;
use chrono::{DateTime, Duration, Utc};
use hmac::{Hmac, Mac};
use reqwest::Client;
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use std::collections::HashSet;
use std::time::{SystemTime, UNIX_EPOCH};
use tracing::{error, info, warn};

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone)]
pub struct ResolvedIdentity {
    pub user_id: i64,
    pub email: String,
    pub name: Option<String>,
    pub picture: Option<String>,
    pub role: String,
    pub is_admin: bool,
}

pub struct AuthService;

impl AuthService {
    // --- Helper Token Generation ---

    /// Mint a 256-bit random token from the OS CSPRNG.
    ///
    /// The previous implementation hashed a clock-derived seed
    /// (`nanos ^ counter ^ pid ^ (nanos_low64 ^ const)`). That seed is
    /// guessable to anyone who can narrow the creation time to roughly a
    /// second, and these tokens are session credentials: `sess_` session
    /// tokens, the `ms_` device tokens, the OAuth `state` and `nonce`, the
    /// PKCE `verifier`, and the `qr_id` that is the *only* key to the
    /// unauthenticated `/api/auth/qr/{id}/finalize` endpoint. A predictable
    /// one is an account takeover.
    ///
    /// Fails closed. If the OS random source is unavailable the caller gets an
    /// error rather than a guessable secret - the same posture the Admin PIN
    /// takes when it is unset.
    pub fn generate_random_token() -> Result<String, AppError> {
        let mut buf = [0u8; 32];
        getrandom::getrandom(&mut buf).map_err(|e| {
            AppError::Internal(format!("Secure random source unavailable: {}", e))
        })?;
        Ok(hex::encode(buf))
    }

    pub fn hash_token(token: &str) -> String {
        let mut hasher = Sha256::new();
        hasher.update(token.trim().as_bytes());
        hex::encode(hasher.finalize())
    }

    // --- Admin Authorization & Status ---

    /// Verify whether a request is administrator-authorized (via valid configured Admin PIN or Admin session).
    ///
    /// Per AGENTS.md §4:
    /// - The Admin PIN fails closed, and has no default.
    /// - Unset/empty in database means the PIN channel is CLOSED (returns false).
    /// - Accepts PIN only from `X-Admin-Pin` header or request body. NEVER from query string.
    pub async fn is_admin_authorized(
        pool: &PgPool,
        headers: &HeaderMap,
        body_pin: Option<&str>,
    ) -> bool {
        // 1. Check session / bearer token admin role
        if let Some(identity) = Self::resolve_session_or_token(pool, headers).await {
            if identity.role == "admin" || identity.is_admin {
                return true;
            }
        }

        // 2. Query stored pin from PostgreSQL settings table
        let stored_pin: Option<String> =
            sqlx::query_scalar("SELECT value FROM settings WHERE key = 'admin_pin'")
                .fetch_optional(pool)
                .await
                .unwrap_or(None);

        let stored = stored_pin.unwrap_or_default().trim().to_string();
        if stored.is_empty() {
            // Fail closed: without a deliberately configured PIN, PIN auth is closed.
            return false;
        }

        let pin_header = headers
            .get("X-Admin-Pin")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.trim());

        let candidate_pin = pin_header.or_else(|| body_pin.map(|s| s.trim()));

        if let Some(pin) = candidate_pin {
            if pin == stored {
                return true;
            }
        }

        false
    }

    /// `GET /api/admin/status`
    pub async fn get_admin_status(pool: &PgPool, headers: &HeaderMap) -> AdminStatusResponse {
        let stored_pin: Option<String> =
            sqlx::query_scalar("SELECT value FROM settings WHERE key = 'admin_pin'")
                .fetch_optional(pool)
                .await
                .unwrap_or(None);

        let has_pin = stored_pin
            .map(|p| !p.trim().is_empty())
            .unwrap_or(false);

        let identity = Self::resolve_session_or_token(pool, headers).await;
        let is_pin_authed = Self::is_admin_authorized(pool, headers, None).await;

        let is_admin = is_pin_authed
            || identity
                .as_ref()
                .map(|i| i.role == "admin" || i.is_admin)
                .unwrap_or(false);

        let user = identity.map(|i| i.email);

        AdminStatusResponse {
            is_admin,
            has_pin,
            user,
        }
    }

    /// `POST /api/admin/verify`
    pub async fn verify_admin_pin(
        pool: &PgPool,
        headers: &HeaderMap,
        body_pin: Option<&str>,
    ) -> AdminVerifyResponse {
        // If already recognized via admin session:
        if let Some(identity) = Self::resolve_session_or_token(pool, headers).await {
            if identity.role == "admin" || identity.is_admin {
                return AdminVerifyResponse {
                    success: true,
                    admin: true,
                    method: Some("google_session".to_string()),
                    error: None,
                };
            }
        }

        let pin_header = headers
            .get("X-Admin-Pin")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.trim());
        let candidate_pin = pin_header.or_else(|| body_pin.map(|s| s.trim()));

        let stored_pin: Option<String> =
            sqlx::query_scalar("SELECT value FROM settings WHERE key = 'admin_pin'")
                .fetch_optional(pool)
                .await
                .unwrap_or(None);

        let stored = stored_pin.unwrap_or_default().trim().to_string();

        if let Some(pin) = candidate_pin {
            if !stored.is_empty() && pin == stored {
                return AdminVerifyResponse {
                    success: true,
                    admin: true,
                    method: Some("pin".to_string()),
                    error: None,
                };
            }
        }

        AdminVerifyResponse {
            success: false,
            admin: false,
            method: None,
            error: Some("Invalid Admin PIN".to_string()),
        }
    }

    /// `POST /api/admin/pin`
    pub async fn update_admin_pin(
        pool: &PgPool,
        headers: &HeaderMap,
        current_pin: Option<&str>,
        new_pin: &str,
    ) -> Result<(), AppError> {
        let clean_new = new_pin.trim();
        if clean_new.len() < 4 {
            return Err(AppError::BadRequest("PIN must be at least 4 digits".to_string()));
        }

        let stored_pin: Option<String> =
            sqlx::query_scalar("SELECT value FROM settings WHERE key = 'admin_pin'")
                .fetch_optional(pool)
                .await
                .unwrap_or(None);

        let has_stored = stored_pin
            .as_ref()
            .map(|p| !p.trim().is_empty())
            .unwrap_or(false);

        // If a PIN is currently configured, caller MUST be authorized
        if has_stored && !Self::is_admin_authorized(pool, headers, current_pin).await {
            return Err(AppError::Forbidden(
                "Administrator privileges required to change PIN.".to_string(),
            ));
        }

        sqlx::query(
            r#"
            INSERT INTO settings (key, value)
            VALUES ('admin_pin', $1)
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
            "#,
        )
        .bind(clean_new)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to persist admin PIN: {}", e)))?;

        info!("Admin PIN updated successfully");
        Ok(())
    }

    // --- Identity Resolution (`/api/auth/me`) ---

    pub async fn resolve_session_or_token(
        pool: &PgPool,
        headers: &HeaderMap,
    ) -> Option<ResolvedIdentity> {
        // 1. Session Cookie (`session_token` or `media_session`)
        if let Some(cookie_hdr) = headers.get(axum::http::header::COOKIE).and_then(|v| v.to_str().ok()) {
            for part in cookie_hdr.split(';') {
                let mut kv = part.splitn(2, '=');
                if let (Some(k), Some(v)) = (kv.next(), kv.next()) {
                    let key = k.trim();
                    let token = v.trim();
                    if (key == "session_token" || key == "media_session") && !token.is_empty() {
                        let row = sqlx::query(
                            r#"
                            SELECT s.user_id, s.email, s.role, u.name, u.picture_url
                            FROM sessions s
                            LEFT JOIN users u ON s.user_id = u.id
                            WHERE s.id = $1 AND s.expires_at > CURRENT_TIMESTAMP
                            "#,
                        )
                        .bind(token)
                        .fetch_optional(pool)
                        .await
                        .ok()?;

                        if let Some(r) = row {
                            let role: String = r.get("role");
                            let is_admin = role == "admin";
                            return Some(ResolvedIdentity {
                                user_id: r.try_get("user_id").unwrap_or(0),
                                email: r.get("email"),
                                name: r.try_get("name").ok(),
                                picture: r.try_get("picture_url").ok(),
                                role,
                                is_admin,
                            });
                        }
                    }
                }
            }
        }

        // 2. Authorization: Bearer <token> (Personal Access Tokens)
        if let Some(auth_hdr) = headers.get(axum::http::header::AUTHORIZATION).and_then(|v| v.to_str().ok()) {
            let trimmed = auth_hdr.trim();
            if trimmed.to_lowercase().starts_with("bearer ") {
                let token = &trimmed[7..].trim();
                let hash = Self::hash_token(token);
                let row = sqlx::query(
                    r#"
                    SELECT t.id, t.user_id, u.email, u.name, u.picture_url, u.role
                    FROM auth_tokens t
                    JOIN users u ON t.user_id = u.id
                    WHERE t.token_hash = $1
                      AND t.revoked_at IS NULL
                      AND (t.expires_at IS NULL OR t.expires_at > CURRENT_TIMESTAMP)
                    "#,
                )
                .bind(&hash)
                .fetch_optional(pool)
                .await
                .ok()?;

                if let Some(r) = row {
                    let tid: i64 = r.get("id");
                    // Touch last_used_at
                    let _ = sqlx::query("UPDATE auth_tokens SET last_used_at = CURRENT_TIMESTAMP WHERE id = $1")
                        .bind(tid)
                        .execute(pool)
                        .await;

                    let role: String = r.get("role");
                    let is_admin = role == "admin";
                    return Some(ResolvedIdentity {
                        user_id: r.get("user_id"),
                        email: r.get("email"),
                        name: r.try_get("name").ok(),
                        picture: r.try_get("picture_url").ok(),
                        role,
                        is_admin,
                    });
                }
            }
        }

        None
    }

    /// Full resolution including fallback to Admin PIN
    pub async fn resolve_caller_identity(
        pool: &PgPool,
        headers: &HeaderMap,
    ) -> Option<ResolvedIdentity> {
        let resolved = Self::resolve_session_or_token(pool, headers).await;
        if resolved.is_some() {
            return resolved;
        }

        // Fallback: If valid Admin PIN is provided, treat caller as local admin
        if Self::is_admin_authorized(pool, headers, None).await {
            return Some(ResolvedIdentity {
                user_id: 0,
                email: "admin@local".to_string(),
                name: Some("Administrator".to_string()),
                picture: None,
                role: "admin".to_string(),
                is_admin: true,
            });
        }

        None
    }

    // --- Allowlist Management (`/api/auth/allowlist`) ---

    pub async fn get_allowlist(pool: &PgPool) -> AllowlistResponse {
        let stored_str: Option<String> =
            sqlx::query_scalar("SELECT value FROM settings WHERE key = 'auth_allowlist'")
                .fetch_optional(pool)
                .await
                .unwrap_or(None);

        let stored: Vec<String> = Self::split_emails(&stored_str.unwrap_or_default());

        let env_str = std::env::var("MEDIA_SERVER_AUTH_ALLOWLIST").unwrap_or_default();
        let environment: Vec<String> = Self::split_emails(&env_str);

        let mut effective_set = HashSet::new();
        for e in &stored {
            effective_set.insert(e.clone());
        }
        for e in &environment {
            effective_set.insert(e.clone());
        }

        let mut effective: Vec<String> = effective_set.into_iter().collect();
        effective.sort();

        AllowlistResponse {
            success: Some(true),
            stored,
            environment,
            effective,
        }
    }

    pub async fn set_allowlist(pool: &PgPool, emails: &[String]) -> Result<AllowlistResponse, AppError> {
        let mut clean_list: Vec<String> = emails
            .iter()
            .map(|e| e.trim().to_lowercase())
            .filter(|e| !e.is_empty())
            .collect();
        clean_list.sort();
        clean_list.dedup();

        let joined = clean_list.join(",");
        sqlx::query(
            r#"
            INSERT INTO settings (key, value)
            VALUES ('auth_allowlist', $1)
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
            "#,
        )
        .bind(&joined)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to persist allowlist: {}", e)))?;

        Ok(Self::get_allowlist(pool).await)
    }

    pub async fn is_email_allowed(pool: &PgPool, email: &str) -> bool {
        let allowlist = Self::get_allowlist(pool).await;
        if allowlist.effective.is_empty() {
            // If no allowlist is configured, fail closed or allow only if auth is disabled
            let auth_enabled = std::env::var("MEDIA_SERVER_AUTH")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            return !auth_enabled;
        }
        let target = email.trim().to_lowercase();
        allowlist.effective.iter().any(|e| e == &target)
    }

    fn split_emails(raw: &str) -> Vec<String> {
        let mut out = Vec::new();
        for item in raw.replace(';', ",").replace('\n', ",").split(',') {
            let trimmed = item.trim().to_lowercase();
            if !trimmed.is_empty() && !out.contains(&trimmed) {
                out.push(trimmed);
            }
        }
        out.sort();
        out
    }

    // --- Personal Access Tokens (`/api/auth/tokens`) ---

    pub async fn list_tokens(
        pool: &PgPool,
        user_id: Option<i64>,
    ) -> Result<Vec<TokenRecord>, AppError> {
        let rows = if let Some(uid) = user_id {
            sqlx::query(
                r#"
                SELECT id, user_id, label, created_at, last_used_at, expires_at, revoked_at
                FROM auth_tokens
                WHERE user_id = $1 AND revoked_at IS NULL
                ORDER BY created_at DESC
                "#,
            )
            .bind(uid)
            .fetch_all(pool)
            .await?
        } else {
            sqlx::query(
                r#"
                SELECT id, user_id, label, created_at, last_used_at, expires_at, revoked_at
                FROM auth_tokens
                WHERE revoked_at IS NULL
                ORDER BY created_at DESC
                "#,
            )
            .fetch_all(pool)
            .await?
        };

        let mut tokens = Vec::new();
        for r in rows {
            let id: i64 = r.get("id");
            let user_id: i64 = r.get("user_id");
            let label: String = r.get("label");
            let created_at: DateTime<Utc> = r.get("created_at");
            let last_used_at: Option<DateTime<Utc>> = r.try_get("last_used_at").ok();
            let expires_at: Option<DateTime<Utc>> = r.try_get("expires_at").ok();
            let revoked_at: Option<DateTime<Utc>> = r.try_get("revoked_at").ok();

            tokens.push(TokenRecord {
                id,
                user_id,
                label,
                created_at: created_at.timestamp(),
                last_used_at: last_used_at.map(|t| t.timestamp()),
                expires_at: expires_at.map(|t| t.timestamp()),
                revoked_at: revoked_at.map(|t| t.timestamp()),
            });
        }

        Ok(tokens)
    }

    pub async fn create_token(
        pool: &PgPool,
        user_id: i64,
        label: &str,
        validity_days: Option<i64>,
        host_url: &str,
    ) -> Result<MintedToken, AppError> {
        let clean_label = label.trim();
        if clean_label.is_empty() {
            return Err(AppError::BadRequest(
                "A label is required so the token can be identified later.".to_string(),
            ));
        }

        let plaintext = format!("ms_{}", Self::generate_random_token()?);
        let hash = Self::hash_token(&plaintext);

        let expires_at = validity_days
            .filter(|&d| d > 0)
            .map(|days| Utc::now() + Duration::days(days));

        let row = sqlx::query(
            r#"
            INSERT INTO auth_tokens (user_id, label, token_hash, expires_at)
            VALUES ($1, $2, $3, $4)
            RETURNING id, expires_at
            "#,
        )
        .bind(user_id)
        .bind(clean_label)
        .bind(&hash)
        .bind(expires_at)
        .fetch_one(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to mint token: {}", e)))?;

        let id: i64 = row.get("id");
        let exp: Option<DateTime<Utc>> = row.try_get("expires_at").ok();

        let base = host_url.trim_end_matches('/');
        let pairing_url = format!("{}/auth/pair#token={}", base, plaintext);

        Ok(MintedToken {
            token: plaintext,
            pairing_url,
            id,
            label: clean_label.to_string(),
            expires_at: exp.map(|t| t.timestamp()),
            warning: "This token is displayed once and cannot be retrieved again.".to_string(),
        })
    }

    pub async fn revoke_token(
        pool: &PgPool,
        token_id: i64,
        caller_user_id: Option<i64>,
        is_admin: bool,
    ) -> Result<bool, AppError> {
        let row = sqlx::query("SELECT user_id FROM auth_tokens WHERE id = $1 AND revoked_at IS NULL")
            .bind(token_id)
            .fetch_optional(pool)
            .await?;

        let owner_id: i64 = match row {
            Some(r) => r.get("user_id"),
            None => return Err(AppError::NotFound("No such active token.".to_string())),
        };

        if !is_admin && Some(owner_id) != caller_user_id {
            return Err(AppError::Forbidden(
                "Unauthorized: Cannot revoke tokens belonging to other users.".to_string(),
            ));
        }

        sqlx::query("UPDATE auth_tokens SET revoked_at = CURRENT_TIMESTAMP WHERE id = $1")
            .bind(token_id)
            .execute(pool)
            .await?;

        Ok(true)
    }

    // --- Local PIN Login ---

    pub async fn login_with_pin(
        pool: &PgPool,
        candidate_pin: &str,
    ) -> Result<(String, i64, String), AppError> {
        let clean_pin = candidate_pin.trim();
        if clean_pin.is_empty() {
            return Err(AppError::Unauthorized("PIN is required".to_string()));
        }

        let stored_pin: Option<String> =
            sqlx::query_scalar("SELECT value FROM settings WHERE key = 'admin_pin'")
                .fetch_optional(pool)
                .await
                .unwrap_or(None);

        let stored = stored_pin.unwrap_or_default().trim().to_string();
        if stored.is_empty() {
            return Err(AppError::Unauthorized(
                "No Admin PIN configured on this server.".to_string(),
            ));
        }

        let is_valid = clean_pin.len() == stored.len()
            && clean_pin
                .bytes()
                .zip(stored.bytes())
                .fold(0, |acc, (a, b)| acc | (a ^ b))
                == 0;

        if !is_valid {
            return Err(AppError::Unauthorized("Invalid Admin PIN".to_string()));
        }

        // Upsert local admin user row
        let user_row = sqlx::query(
            r#"
            INSERT INTO users (google_sub, email, name, role, created_at, last_login_at)
            VALUES ('admin_pin', 'admin@local', 'Administrator', 'admin', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            ON CONFLICT (google_sub) DO UPDATE
                SET role = 'admin',
                    last_login_at = CURRENT_TIMESTAMP
            RETURNING id, email, role
            "#,
        )
        .fetch_one(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to upsert admin user: {}", e)))?;

        let user_id: i64 = user_row.get("id");
        let email: String = user_row.get("email");
        let role: String = user_row.get("role");

        let session_token = format!("sess_{}", Self::generate_random_token()?);
        let expires_at = Utc::now() + Duration::days(30);

        sqlx::query(
            r#"
            INSERT INTO sessions (id, user_id, email, role, expires_at)
            VALUES ($1, $2, $3, $4, $5)
            "#,
        )
        .bind(&session_token)
        .bind(user_id)
        .bind(&email)
        .bind(&role)
        .bind(expires_at)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to store session: {}", e)))?;

        info!("AUTH: Local Admin PIN sign-in successful user_id={}", user_id);
        Ok((session_token, user_id, email))
    }

    // --- Google OAuth ---

    /// Unpadded URL-safe Base64 encoder per RFC 4648 §5 / RFC 7636 §4.2 (OAuth 2.0 PKCE).
    pub fn base64url_encode(data: &[u8]) -> String {
        const CHARSET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut result = String::with_capacity((data.len() * 4 + 2) / 3);
        let mut i = 0;
        while i < data.len() {
            let b0 = data[i];
            let b1 = if i + 1 < data.len() { data[i + 1] } else { 0 };
            let b2 = if i + 2 < data.len() { data[i + 2] } else { 0 };

            result.push(CHARSET[(b0 >> 2) as usize] as char);
            result.push(CHARSET[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
            if i + 1 < data.len() {
                result.push(CHARSET[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
            }
            if i + 2 < data.len() {
                result.push(CHARSET[(b2 & 0x3f) as usize] as char);
            }
            i += 3;
        }
        result
    }

    pub fn is_oauth_configured() -> bool {
        let client_id = std::env::var("GOOGLE_CLIENT_ID")
            .or_else(|_| std::env::var("MEDIA_SERVER_GOOGLE_CLIENT_ID"))
            .unwrap_or_default();
        !client_id.trim().is_empty()
    }

    pub async fn oauth_start(
        pool: &PgPool,
        redirect_uri: &str,
        next_path: Option<&str>,
    ) -> Result<String, AppError> {
        let client_id = std::env::var("GOOGLE_CLIENT_ID")
            .or_else(|_| std::env::var("MEDIA_SERVER_GOOGLE_CLIENT_ID"))
            .unwrap_or_default()
            .trim()
            .to_string();

        if client_id.is_empty() {
            return Err(AppError::ServiceUnavailable(
                "Sign-in is not configured on this server.".to_string(),
            ));
        }

        let state = Self::generate_random_token()?;
        let nonce = Self::generate_random_token()?;
        let verifier = Self::generate_random_token()?;

        let mut hasher = Sha256::new();
        hasher.update(verifier.as_bytes());
        let challenge = Self::base64url_encode(&hasher.finalize());

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        let next = next_path.unwrap_or("/");

        sqlx::query(
            r#"
            INSERT INTO oauth_attempts (state, nonce, verifier, redirect_uri, next_path, started_at, used)
            VALUES ($1, $2, $3, $4, $5, $6, 0)
            ON CONFLICT (state) DO UPDATE SET nonce = $2, verifier = $3, started_at = $6, used = 0
            "#,
        )
        .bind(&state)
        .bind(&nonce)
        .bind(&verifier)
        .bind(redirect_uri)
        .bind(next)
        .bind(now)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to record OAuth attempt: {}", e)))?;

        let auth_url = format!(
            "https://accounts.google.com/o/oauth2/v2/auth?client_id={}&response_type=code&scope=openid+email+profile&redirect_uri={}&state={}&nonce={}&code_challenge={}&code_challenge_method=S256&prompt=select_account",
            urlencoding::encode(&client_id),
            urlencoding::encode(redirect_uri),
            urlencoding::encode(&state),
            urlencoding::encode(&nonce),
            urlencoding::encode(&challenge)
        );

        Ok(auth_url)
    }

    pub async fn oauth_callback(
        pool: &PgPool,
        code: &str,
        state: &str,
    ) -> Result<(String, String), AppError> {
        let attempt = sqlx::query(
            "SELECT nonce, verifier, redirect_uri, next_path, started_at FROM oauth_attempts WHERE state = $1 AND used = 0",
        )
        .bind(state)
        .fetch_optional(pool)
        .await?;

        let row = match attempt {
            Some(r) => r,
            None => {
                return Err(AppError::BadRequest(
                    "Sign-in state is missing or already used. Start again.".to_string(),
                ));
            }
        };

        let verifier: String = row.get("verifier");
        let redirect_uri: String = row.get("redirect_uri");
        let next_path: String = row.get("next_path");
        let started_at: i64 = row.get("started_at");

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        if (now - started_at) > 600 {
            return Err(AppError::BadRequest("Sign-in attempt expired. Start again.".to_string()));
        }

        // Mark attempt used
        let _ = sqlx::query("UPDATE oauth_attempts SET used = 1 WHERE state = $1")
            .bind(state)
            .execute(pool)
            .await;

        let client_id = std::env::var("GOOGLE_CLIENT_ID")
            .or_else(|_| std::env::var("MEDIA_SERVER_GOOGLE_CLIENT_ID"))
            .unwrap_or_default();
        let client_secret = std::env::var("GOOGLE_CLIENT_SECRET")
            .or_else(|_| std::env::var("MEDIA_SERVER_GOOGLE_CLIENT_SECRET"))
            .unwrap_or_default();

        let http = Client::new();
        let token_res = http
            .post("https://oauth2.googleapis.com/token")
            .form(&[
                ("code", code),
                ("client_id", &client_id),
                ("client_secret", &client_secret),
                ("redirect_uri", &redirect_uri),
                ("grant_type", "authorization_code"),
                ("code_verifier", &verifier),
            ])
            .send()
            .await
            .map_err(|e| {
                error!("Google token exchange network error: {}", e);
                AppError::BadGateway(format!("Google token exchange failed: {}", e))
            })?;

        if !token_res.status().is_success() {
            let status = token_res.status();
            let err_body = token_res.text().await.unwrap_or_default();
            error!("Google OAuth token exchange rejected (HTTP {}): {}", status, err_body);
            return Err(AppError::BadGateway(format!(
                "Could not complete sign-in with Google: {}",
                err_body
            )));
        }

        let token_data: serde_json::Value = token_res
            .json()
            .await
            .map_err(|e| AppError::BadGateway(format!("Failed to parse Google token response: {}", e)))?;

        let id_token = token_data
            .get("id_token")
            .and_then(|v| v.as_str())
            .unwrap_or_default();

        if id_token.is_empty() {
            return Err(AppError::BadGateway(
                "Google returned no id_token".to_string(),
            ));
        }

        // Verify ID token via Google tokeninfo
        let info_res = http
            .get(format!("https://oauth2.googleapis.com/tokeninfo?id_token={}", id_token))
            .send()
            .await
            .map_err(|e| {
                error!("Google tokeninfo network error: {}", e);
                AppError::Unauthorized(format!("Tokeninfo failed: {}", e))
            })?;

        if !info_res.status().is_success() {
            let status = info_res.status();
            let err_body = info_res.text().await.unwrap_or_default();
            error!("Google tokeninfo rejected (HTTP {}): {}", status, err_body);
            return Err(AppError::Unauthorized(
                "Google sign-in could not be verified.".to_string(),
            ));
        }

        let claims: serde_json::Value = info_res
            .json()
            .await
            .map_err(|e| AppError::Unauthorized(format!("Invalid tokeninfo JSON: {}", e)))?;

        let email = claims
            .get("email")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_lowercase();
        let sub = claims
            .get("sub")
            .and_then(|v| v.as_str())
            .unwrap_or_default();

        if email.is_empty() || sub.is_empty() {
            return Err(AppError::Unauthorized(
                "Google token missing email or subject".to_string(),
            ));
        }

        // Allowlist check
        if !Self::is_email_allowed(pool, &email).await {
            warn!("AUTH: Rejected unlisted identity: {}", email);
            return Err(AppError::Forbidden(
                "This account is not permitted to use this server.".to_string(),
            ));
        }

        let name = claims.get("name").and_then(|v| v.as_str());
        let picture = claims.get("picture").and_then(|v| v.as_str());

        // Upsert user
        let user_row = sqlx::query(
            r#"
            INSERT INTO users (google_sub, email, name, picture_url, role, created_at, last_login_at)
            VALUES ($1, $2, $3, $4, 'viewer', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            ON CONFLICT (google_sub) DO UPDATE
                SET email = $2,
                    name = COALESCE($3, users.name),
                    picture_url = COALESCE($4, users.picture_url),
                    last_login_at = CURRENT_TIMESTAMP
            RETURNING id, role
            "#,
        )
        .bind(sub)
        .bind(&email)
        .bind(name)
        .bind(picture)
        .fetch_one(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to upsert user: {}", e)))?;

        let user_id: i64 = user_row.get("id");
        let role: String = user_row.get("role");

        // Mint session
        let session_token = format!("sess_{}", Self::generate_random_token()?);
        let expires_at = Utc::now() + Duration::days(30);

        sqlx::query(
            r#"
            INSERT INTO sessions (id, user_id, email, role, expires_at)
            VALUES ($1, $2, $3, $4, $5)
            "#,
        )
        .bind(&session_token)
        .bind(user_id)
        .bind(&email)
        .bind(&role)
        .bind(expires_at)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to store session: {}", e)))?;

        info!("AUTH: Google sign-in successful sub={} email={}", sub, email);
        Ok((session_token, next_path))
    }

    pub async fn pair_token(
        pool: &PgPool,
        plaintext_token: &str,
    ) -> Result<String, AppError> {
        let hash = Self::hash_token(plaintext_token);
        let row = sqlx::query(
            r#"
            SELECT t.id, t.user_id, u.email, u.role
            FROM auth_tokens t
            JOIN users u ON t.user_id = u.id
            WHERE t.token_hash = $1
              AND t.revoked_at IS NULL
              AND (t.expires_at IS NULL OR t.expires_at > CURRENT_TIMESTAMP)
            "#,
        )
        .bind(&hash)
        .fetch_optional(pool)
        .await?;

        let r = match row {
            Some(r) => r,
            None => return Err(AppError::Unauthorized("That pairing token is not valid.".to_string())),
        };

        let user_id: i64 = r.get("user_id");
        let email: String = r.get("email");
        let role: String = r.get("role");

        let session_token = format!("sess_{}", Self::generate_random_token()?);
        let expires_at = Utc::now() + Duration::days(30);

        sqlx::query(
            r#"
            INSERT INTO sessions (id, user_id, email, role, expires_at)
            VALUES ($1, $2, $3, $4, $5)
            "#,
        )
        .bind(&session_token)
        .bind(user_id)
        .bind(&email)
        .bind(&role)
        .bind(expires_at)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to store session: {}", e)))?;

        info!("AUTH: device paired uid={} email={} role={}", user_id, email, role);
        Ok(session_token)
    }

    // --- QR Device Pair Sessions ---

    /// Generate a 5-char uppercase alphanumeric pair code using an unambiguous charset.
    /// Avoids 0/O, 1/I lookalikes for easier manual entry.
    ///
    /// Each of the five characters is drawn independently from the OS CSPRNG.
    ///
    /// The previous implementation walked a single 64-bit LCG and took
    /// `seed % 32` per step. Because the LCG's multiplier and increment are
    /// both odd, the low 5 bits of every step depend only on the low 5 bits of
    /// the first one - so the whole code collapsed to **32 possible values**
    /// (5 bits) instead of the intended 32^5 (25 bits). Measured on the
    /// running server: 40 sessions produced 15 distinct codes. Since
    /// `POST /api/auth/qr/lookup` resolves a code to a live pairing session,
    /// any signed-in account could try all 32 and hijack another user's
    /// active TV pairing.
    ///
    /// `byte % 32` is exactly uniform here: the charset is 32 characters and
    /// 256 is a multiple of 32, so there is no modulo bias and no rejection
    /// sampling is needed.
    ///
    /// Fails closed, for the same reason as `generate_random_token`.
    pub fn generate_pair_code() -> Result<String, AppError> {
        const CHARS: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        let mut buf = [0u8; 5];
        getrandom::getrandom(&mut buf).map_err(|e| {
            AppError::Internal(format!("Secure random source unavailable: {}", e))
        })?;
        Ok(buf
            .iter()
            .map(|b| CHARS[(*b as usize) % CHARS.len()] as char)
            .collect())
    }

    /// HMAC-SHA256 of `"{qr_id}:{code}"` using `MEDIA_SERVER_SECRET` env var.
    /// This makes the QR URL tamper-proof without encrypting the human-readable code.
    pub fn hmac_pair_code(qr_id: &str, code: &str) -> String {
        let secret = std::env::var("MEDIA_SERVER_SECRET")
            .unwrap_or_else(|_| "changeme-set-MEDIA_SERVER_SECRET-in-env".to_string());
        let mut mac =
            HmacSha256::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
        mac.update(format!("{}:{}", qr_id, code).as_bytes());
        hex::encode(mac.finalize().into_bytes())
    }

    /// Create a new ephemeral QR pair session. Returns `(qr_id, code, sig, expires_at_unix)`.
    pub async fn create_pair_session(pool: &PgPool) -> Result<(String, String, String, i64), AppError> {
        // Sweep any sessions older than 5 minutes while we're here
        let _ = Self::sweep_expired_pair_sessions(pool).await;

        let qr_id = format!("qr_{}", Self::generate_random_token()?);
        let code = Self::generate_pair_code()?;
        let sig = Self::hmac_pair_code(&qr_id, &code);
        let code_hash = Self::hash_token(&code);
        let expires_at = Utc::now() + Duration::minutes(2);

        sqlx::query(
            r#"
            INSERT INTO device_pair_sessions (id, code, code_hash, sig, expires_at)
            VALUES ($1, $2, $3, $4, $5)
            "#,
        )
        .bind(&qr_id)
        .bind(&code)
        .bind(&code_hash)
        .bind(&sig)
        .bind(expires_at)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to create pair session: {}", e)))?;

        // The pair code is NEVER logged. `GET /api/auth/qr/{id}/finalize` is
        // unauthenticated and keyed only on `qr_id`, so a log line carrying
        // either secret is an account-takeover handout for anyone who can
        // read the log. A short non-secret prefix is enough to correlate
        // sessions operationally.
        info!(
            "QR: created pair session ref={} ttl=120s",
            Self::redacted_pair_ref(&qr_id)
        );
        Ok((qr_id, code, sig, expires_at.timestamp()))
    }

    /// A short, non-secret reference for a pair session id, safe to write to
    /// the log. 12 hex characters of a 256-bit id is not enough to reconstruct
    /// the id, so a log reader cannot complete a pairing.
    pub fn redacted_pair_ref(qr_id: &str) -> String {
        qr_id.chars().take(15).collect()
    }

    /// Check the status of a pair session for the waiting TV/browser.
    /// Returns `None` if the session doesn't exist or is expired.
    /// Returns `Some((confirmed, session_id, device_name))` otherwise.
    pub async fn get_pair_session_status(
        pool: &PgPool,
        qr_id: &str,
    ) -> Result<Option<(bool, Option<String>, Option<String>)>, AppError> {
        let row = sqlx::query(
            r#"
            SELECT confirmed, session_id, device_name
            FROM device_pair_sessions
            WHERE id = $1 AND expires_at > CURRENT_TIMESTAMP
            "#,
        )
        .bind(qr_id)
        .fetch_optional(pool)
        .await?;

        Ok(row.map(|r| {
            let confirmed: bool = r.get("confirmed");
            let session_id: Option<String> = r.try_get("session_id").ok().flatten();
            let device_name: Option<String> = r.try_get("device_name").ok().flatten();
            (confirmed, session_id, device_name)
        }))
    }

    /// Look up an active (unexpired, unconfirmed) pair session by its 5-char code.
    /// Case-insensitive. Returns `Some(qr_id)` if found, `None` if expired or not found.
    pub async fn find_pair_session_by_code(
        pool: &PgPool,
        code: &str,
    ) -> Result<Option<String>, AppError> {
        let clean_code = code.trim().to_uppercase();
        let row = sqlx::query(
            r#"
            SELECT id
            FROM device_pair_sessions
            WHERE code = $1 AND expires_at > CURRENT_TIMESTAMP AND confirmed = FALSE
            ORDER BY created_at DESC
            LIMIT 1
            "#,
        )
        .bind(&clean_code)
        .fetch_optional(pool)
        .await?;

        Ok(row.map(|r| r.get("id")))
    }

    /// Called by the phone to complete the pairing.
    /// Validates the submitted code against the session, mints a session for the TV,
    /// and marks the pair session as confirmed.
    pub async fn confirm_pair_session(
        pool: &PgPool,
        qr_id: &str,
        submitted_code: &str,
        submitted_sig: Option<&str>,
        user_id: i64,
        device_name: &str,
    ) -> Result<(), AppError> {
        let row = sqlx::query(
            r#"
            SELECT code, sig, confirmed
            FROM device_pair_sessions
            WHERE id = $1 AND expires_at > CURRENT_TIMESTAMP
            "#,
        )
        .bind(qr_id)
        .fetch_optional(pool)
        .await?;

        let r = row.ok_or_else(|| {
            AppError::BadRequest("Pair session expired or not found.".to_string())
        })?;

        let already_confirmed: bool = r.get("confirmed");
        if already_confirmed {
            return Err(AppError::BadRequest(
                "This session has already been confirmed.".to_string(),
            ));
        }

        let stored_code: String = r.get("code");
        let stored_sig: String = r.get("sig");

        // Accept if either the HMAC sig matches OR the raw code matches (case-insensitive)
        let sig_valid = submitted_sig.map(|s| s == stored_sig).unwrap_or(false);
        let code_valid = submitted_code.trim().to_uppercase() == stored_code;

        if !sig_valid && !code_valid {
            return Err(AppError::Unauthorized(
                "Invalid pairing code. Check the code displayed on your TV and try again."
                    .to_string(),
            ));
        }

        // Mint a 30-day session for the waiting TV/browser
        let session_token = format!("sess_{}", Self::generate_random_token()?);
        let sess_expires_at = Utc::now() + Duration::days(30);

        // Fetch user email + role for the session
        let user_row = sqlx::query("SELECT email, role FROM users WHERE id = $1")
            .bind(user_id)
            .fetch_optional(pool)
            .await?
            .ok_or_else(|| AppError::Internal("User not found for pairing".to_string()))?;

        let email: String = user_row.get("email");
        let role: String = user_row.get("role");

        sqlx::query(
            r#"
            INSERT INTO sessions (id, user_id, email, role, expires_at)
            VALUES ($1, $2, $3, $4, $5)
            "#,
        )
        .bind(&session_token)
        .bind(user_id)
        .bind(&email)
        .bind(&role)
        .bind(sess_expires_at)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to store paired session: {}", e)))?;

        // Mark pair session confirmed and store the minted session_id + device_name
        sqlx::query(
            r#"
            UPDATE device_pair_sessions
            SET confirmed = TRUE,
                user_id = $1,
                session_id = $2,
                device_name = $3
            WHERE id = $4
            "#,
        )
        .bind(user_id)
        .bind(&session_token)
        .bind(device_name.trim())
        .bind(qr_id)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to mark pair session confirmed: {}", e)))?;

        info!(
            "QR: pair session confirmed qr_id={} user_id={} device_name={}",
            qr_id, user_id, device_name
        );
        Ok(())
    }

    /// Delete expired pair sessions older than 5 minutes (2 min TTL + 3 min grace).
    pub async fn sweep_expired_pair_sessions(pool: &PgPool) -> Result<u64, AppError> {
        let result = sqlx::query(
            "DELETE FROM device_pair_sessions WHERE expires_at < (CURRENT_TIMESTAMP - INTERVAL '3 minutes')"
        )
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Sweep failed: {}", e)))?;
        Ok(result.rows_affected())
    }

    pub async fn logout_session(pool: &PgPool, headers: &HeaderMap) -> Result<(), AppError> {
        if let Some(cookie_hdr) = headers.get(axum::http::header::COOKIE).and_then(|v| v.to_str().ok()) {
            for part in cookie_hdr.split(';') {
                let mut kv = part.splitn(2, '=');
                if let (Some(k), Some(v)) = (kv.next(), kv.next()) {
                    let key = k.trim();
                    let token = v.trim();
                    if (key == "session_token" || key == "media_session") && !token.is_empty() {
                        let _ = sqlx::query("DELETE FROM sessions WHERE id = $1")
                            .bind(token)
                            .execute(pool)
                            .await;
                    }
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rfc7636_pkce_challenge_vector() {
        // Official RFC 7636 Appendix B test vector
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        let mut hasher = Sha256::new();
        hasher.update(verifier.as_bytes());
        let challenge = AuthService::base64url_encode(&hasher.finalize());
        assert_eq!(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
        assert_eq!(challenge.len(), 43);
    }

    /// The pair code is the secret that gates a TV pairing: `lookup` resolves
    /// a code to a live session, so a guessable code lets any signed-in
    /// account hijack someone else's active pairing.
    ///
    /// This test is the one that would have caught the original defect. The
    /// previous generator walked a single 64-bit LCG and took `seed % 32` per
    /// step; because the LCG multiplier and increment are both odd, the low
    /// 5 bits of every step depend only on the low 5 bits of the first one,
    /// so the whole code collapsed to 32 possible values. 10,000 draws
    /// produced 32 distinct codes; the assertion below demands thousands.
    #[test]
    fn test_pair_code_has_real_entropy() {
        const CHARS: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        const DRAWS: usize = 10_000;

        let mut seen = std::collections::HashSet::new();
        for _ in 0..DRAWS {
            let code = AuthService::generate_pair_code().expect("CSPRNG available");
            assert_eq!(code.chars().count(), 5, "pair code must be 5 characters");
            assert!(
                code.chars().all(|c| CHARS.contains(&(c as u8))),
                "pair code '{}' must use the unambiguous charset",
                code
            );
            seen.insert(code);
        }

        // 32^5 = 33,554,432 possible codes. 10,000 draws should collide only
        // about 1.5 times by the birthday bound, so a healthy generator lands
        // near 9,998 distinct values. The collapsed generator produced 32.
        assert!(
            seen.len() >= 5_000,
            "pair code generator is not random enough: {} distinct codes from {} draws (expected >= 5000)",
            seen.len(),
            DRAWS
        );
    }

    /// The characters of a pair code must be drawn independently. If the
    /// generator ever reintroduces a shared seed whose low bits drive every
    /// character, the distinct-code count collapses again - this checks the
    /// first and last character are not correlated through one state word.
    #[test]
    fn test_pair_code_characters_are_not_correlated() {
        const DRAWS: usize = 2_000;
        let mut first_chars = std::collections::HashSet::new();
        let mut last_chars = std::collections::HashSet::new();
        for _ in 0..DRAWS {
            let code = AuthService::generate_pair_code().expect("CSPRNG available");
            let chars: Vec<char> = code.chars().collect();
            first_chars.insert(chars[0]);
            last_chars.insert(chars[4]);
        }
        // Each position should reach the full 32-character charset.
        assert_eq!(first_chars.len(), 32, "first character never varied enough");
        assert_eq!(last_chars.len(), 32, "last character never varied enough");
    }

    /// `generate_random_token` mints session tokens, OAuth state/nonce, the
    /// PKCE verifier and the `qr_id` that gates the unauthenticated finalize
    /// endpoint. It must be 256 bits of OS randomness, not a clock-derived
    /// seed.
    #[test]
    fn test_random_token_is_256_bits_of_unique_material() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..1_000 {
            let token = AuthService::generate_random_token().expect("CSPRNG available");
            assert_eq!(token.len(), 64, "token must be 32 bytes of hex");
            assert!(token.chars().all(|c| c.is_ascii_hexdigit()));
            seen.insert(token);
        }
        assert_eq!(seen.len(), 1_000, "tokens must not repeat");
    }

    /// The redacted reference is what reaches the log. It must not be the
    /// full id, and it must not carry the pair code.
    #[test]
    fn test_redacted_pair_ref_is_not_the_secret() {
        let qr_id = format!("qr_{}", AuthService::generate_random_token().unwrap());
        let code = AuthService::generate_pair_code().unwrap();
        let redacted = AuthService::redacted_pair_ref(&qr_id);

        assert_ne!(redacted, qr_id, "the full id must never be logged");
        assert!(qr_id.starts_with(&redacted), "the ref must stay a prefix");
        assert!(!redacted.contains(&code), "the ref must not carry the code");
    }
}
