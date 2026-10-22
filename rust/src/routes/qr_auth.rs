/// QR Device Sign-In Routes
///
/// Implements the two-device handshake for signing in on TVs and browsers
/// without needing to type credentials:
///
/// 1. `POST /api/auth/qr`              — TV creates a pair session, gets QR data
/// 2. `GET  /api/auth/qr/{id}/wait`    — TV waits via SSE; pushed on confirmation
/// 3. `GET  /api/auth/qr/{id}/status`  — TV polls (fallback for SSE-hostile proxies)
/// 4. `POST /api/auth/qr/{id}/confirm` — Phone confirms after Google sign-in
/// 5. `GET  /api/auth/qr/{id}/finalize`— TV proves it owns the session
///    (path-scoped secret cookie from step 1) and receives the session cookie
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
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::Duration;

// ─── Abuse bounds ────────────────────────────────────────────────────────────
//
// The QR routes are reachable from the public internet through Caddy and need
// no session to be hit, so they are the cheapest way to make this server work
// for someone else: every `create` writes a row, and every `wait` holds a
// connection plus a database query every three seconds.
//
// These are denial-of-service brakes, not authorization controls. A real TV
// creates one session per two minutes and keeps one wait open, so the budgets
// below are roughly an order of magnitude of headroom.

/// Sliding-window length for every per-identity budget.
const RATE_WINDOW: Duration = Duration::from_secs(60);

/// Per-identity attempts allowed per window, by route.
const LIMIT_CREATE: usize = 10;
const LIMIT_LOOKUP: usize = 20;
const LIMIT_CONFIRM: usize = 20;
const LIMIT_FINALIZE: usize = 30;
const LIMIT_WAIT: usize = 10;
const LIMIT_STATUS: usize = 120;

/// Concurrent SSE streams: global pool (overridable) and per client.
const SSE_MAX_GLOBAL_DEFAULT: usize = 64;
const SSE_MAX_PER_IP: usize = 4;

/// Upper bound on tracked identities, so churning `X-Forwarded-For` values
/// cannot grow the table without bound.
const RATE_MAX_IDENTITIES: usize = 8192;

/// Per-identity sliding-window counter.
///
/// Deliberately in-process and dependency-free: the service is one process and
/// this guards availability, not identity, so losing counters on restart costs
/// nothing. When the identity table is full a *new* identity is refused rather
/// than evicting a live one, because eviction would hand an attacker a fresh
/// budget on every spoofed address.
pub struct RateLimiter {
    windows: Mutex<HashMap<String, VecDeque<Instant>>>,
}

impl RateLimiter {
    fn new() -> Self {
        Self {
            windows: Mutex::new(HashMap::new()),
        }
    }

    /// Count one attempt. `Err(retry_after_secs)` means the caller is over
    /// budget and the request must be refused with that delay.
    fn check(&self, bucket: &str, identity: &str, limit: usize) -> Result<(), u64> {
        self.check_window(bucket, identity, limit, RATE_WINDOW)
    }

    fn check_window(
        &self,
        bucket: &str,
        identity: &str,
        limit: usize,
        window: Duration,
    ) -> Result<(), u64> {
        let key = format!("{}:{}", bucket, identity);
        let now = Instant::now();
        let mut windows = self.windows.lock().unwrap_or_else(|e| e.into_inner());

        // Opportunistic pruning keeps the table proportional to live clients.
        if windows.len() > RATE_MAX_IDENTITIES {
            windows.retain(|_, hits| {
                hits.back()
                    .map(|t| now.duration_since(*t) < window)
                    .unwrap_or(false)
            });
        }
        if !windows.contains_key(&key) && windows.len() >= RATE_MAX_IDENTITIES {
            return Err(window.as_secs().max(1));
        }

        let hits = windows.entry(key).or_default();
        while let Some(front) = hits.front() {
            if now.duration_since(*front) >= window {
                hits.pop_front();
            } else {
                break;
            }
        }
        if hits.len() >= limit {
            let oldest = *hits.front().expect("queue is non-empty when over budget");
            let remaining = window.saturating_sub(now.duration_since(oldest));
            return Err(remaining.as_secs().max(1));
        }
        hits.push_back(now);
        Ok(())
    }
}

/// Admission control for concurrent SSE streams.
///
/// The global pool bounds the whole server; the per-identity count stops one
/// client from occupying all of it. Both are released by dropping the returned
/// permit, which is moved into the response stream - so a disconnect, a
/// timeout, or a proxy that never reads the body all give the capacity back.
pub struct SseGate {
    permits: Arc<Semaphore>,
    by_identity: Mutex<HashMap<String, usize>>,
}

pub struct SsePermit {
    _permit: OwnedSemaphorePermit,
    gate: Arc<SseGate>,
    identity: String,
}

impl Drop for SsePermit {
    fn drop(&mut self) {
        let mut by_identity = self.gate.by_identity.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(count) = by_identity.get_mut(&self.identity) {
            *count -= 1;
            if *count == 0 {
                by_identity.remove(&self.identity);
            }
        }
    }
}

impl SseGate {
    fn new(max_global: usize) -> Arc<Self> {
        Arc::new(Self {
            permits: Arc::new(Semaphore::new(max_global)),
            by_identity: Mutex::new(HashMap::new()),
        })
    }

    fn try_acquire(self: &Arc<Self>, identity: &str) -> Option<SsePermit> {
        {
            let mut by_identity =
                self.by_identity.lock().unwrap_or_else(|e| e.into_inner());
            let count = by_identity.entry(identity.to_string()).or_insert(0);
            if *count >= SSE_MAX_PER_IP {
                return None;
            }
            *count += 1;
        }

        match self.permits.clone().try_acquire_owned() {
            Ok(permit) => Some(SsePermit {
                _permit: permit,
                gate: self.clone(),
                identity: identity.to_string(),
            }),
            Err(_) => {
                // The global pool is full: undo the per-identity reservation so
                // a later attempt is judged on the pool alone.
                let mut by_identity =
                    self.by_identity.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(count) = by_identity.get_mut(identity) {
                    *count -= 1;
                    if *count == 0 {
                        by_identity.remove(identity);
                    }
                }
                None
            }
        }
    }
}

#[derive(Clone)]
pub struct QrAuthState {
    pub pool: Arc<PgPool>,
    pub limiter: Arc<RateLimiter>,
    pub sse: Arc<SseGate>,
}

impl QrAuthState {
    pub fn new(pool: Arc<PgPool>) -> Self {
        let max_sse = std::env::var("MEDIA_SERVER_QR_MAX_SSE")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|n| *n > 0)
            .unwrap_or(SSE_MAX_GLOBAL_DEFAULT);
        Self {
            pool,
            limiter: Arc::new(RateLimiter::new()),
            sse: SseGate::new(max_sse),
        }
    }
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

/// The origin the QR URL and the login URL are built from.
///
/// A configured public origin (`MEDIA_SERVER_PUBLIC_BASE_URL`) wins over the
/// request headers. The headers are attacker-influenced - a client can send
/// any `Host` it likes - and this value is what the phone is told to open, so
/// a forged `Host` would otherwise point the pairing flow at a host of the
/// attacker's choosing.
fn get_base_url(headers: &HeaderMap) -> String {
    if let Some(origin) = crate::config::public_base_url() {
        return origin;
    }
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

/// The identity used for per-client budgets.
///
/// The public origin is reached only through Caddy, which supplies
/// `X-Forwarded-For`; the **last** entry is the client as the closest proxy saw
/// it, which is correct whether Caddy appends to or replaces the header.
///
/// Direct LAN requests carry no header and share one bucket. That is safe even
/// though the bucket is coarser than a per-host one: ports 80 and 443 are the
/// only forwarded ports, so a public caller cannot bypass Caddy and forge the
/// header - and a LAN caller is already inside the trust boundary. The length
/// is capped because the value becomes a table key.
fn client_identity(headers: &HeaderMap) -> String {
    headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .and_then(|raw| raw.rsplit(',').next())
        .map(|ip| ip.trim())
        .filter(|ip| !ip.is_empty())
        .map(|ip| ip.chars().take(64).collect())
        .unwrap_or_else(|| "direct".to_string())
}

/// Enforce one route's per-identity budget, answering 429 with `Retry-After`.
fn enforce(
    state: &QrAuthState,
    headers: &HeaderMap,
    bucket: &str,
    limit: usize,
) -> Result<(), AppError> {
    state
        .limiter
        .check(bucket, &client_identity(headers), limit)
        .map_err(AppError::TooManyRequests)
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// `POST /api/auth/qr`
///
/// Creates a new QR pair session. The TV/browser calls this immediately on
/// page load to get the QR data to display.
///
/// The response also sets a path-scoped `ms_qr_secret` cookie. That cookie is
/// the calling device's proof of ownership for `finalize`; the secret itself
/// is never placed in the JSON body (the page must not be able to read it, and
/// it must not end up in screenshots or copy-paste).
pub async fn create_pair_session_handler(
    State(state): State<QrAuthState>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    enforce(&state, &headers, "create", LIMIT_CREATE)?;

    let (qr_id, code, sig, expires_at, secret) =
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

    let mut res = Json(CreateQrResponse {
        qr_id: qr_id.clone(),
        code,
        sig,
        expires_at,
        qr_url,
        login_url,
    })
    .into_response();

    if let Ok(cookie) =
        header::HeaderValue::from_str(&AuthService::qr_secret_cookie(&qr_id, &secret, &headers))
    {
        res.headers_mut().append(header::SET_COOKIE, cookie);
    }

    Ok(res)
}

/// `POST /api/auth/qr/lookup`
///
/// Resolves a manually entered 5-char code on the phone to an active `qr_id`.
pub async fn qr_lookup_handler(
    State(state): State<QrAuthState>,
    headers: HeaderMap,
    Json(payload): Json<LookupQrPayload>,
) -> Result<Json<LookupQrResponse>, AppError> {
    // Limit before the auth lookup: an unauthenticated flood must not reach the
    // session resolver either.
    enforce(&state, &headers, "lookup", LIMIT_LOOKUP)?;

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
    headers: HeaderMap,
) -> Result<Response, AppError> {
    use axum::body::Body;
    use tokio::sync::mpsc;

    enforce(&state, &headers, "wait", LIMIT_WAIT)?;

    let identity = client_identity(&headers);
    let Some(permit) = state.sse.try_acquire(&identity) else {
        // A refused stream retries sooner than a refused request: the stream
        // that holds the slot usually finishes or disconnects within the
        // session's two-minute life.
        return Err(AppError::TooManyRequests(5));
    };

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

    // Convert the mpsc receiver into a byte stream for the HTTP response body.
    //
    // The SSE permit rides in the stream state: dropping the stream (client
    // disconnect, timeout, proxy that never reads) drops the permit with it, so
    // capacity cannot leak away from the pool.
    let byte_stream = futures_util::stream::unfold((rx, permit), |(mut rx, permit)| async move {
        rx.recv().await.map(|frame| {
            let bytes = axum::body::Bytes::from(frame.into_bytes());
            (Ok::<_, std::convert::Infallible>(bytes), (rx, permit))
        })
    });

    Ok(axum::response::Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .header("X-Accel-Buffering", "no") // tell reverse proxies not to buffer SSE
        .body(Body::from_stream(byte_stream))
        .expect("SSE response is valid"))
}

/// `GET /api/auth/qr/{id}/status`
///
/// Simple poll endpoint — fallback for environments where SSE is not reliable.
pub async fn qr_status_handler(
    Path(qr_id): Path<String>,
    State(state): State<QrAuthState>,
    headers: HeaderMap,
) -> Result<Json<QrStatusResponse>, AppError> {
    enforce(&state, &headers, "status", LIMIT_STATUS)?;

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
    // Meter before the session lookup: a flood of guesses must not become a
    // flood of database work, and the phone legitimately confirms once.
    enforce(&state, &headers, "confirm", LIMIT_CONFIRM)?;

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
///
/// **Bound to the waiting device.** Possession of `qr_id` is not enough: the
/// caller must also present the path-scoped `ms_qr_secret` cookie issued by
/// `POST /api/auth/qr`. Without it (or with the wrong one) this answers 403
/// and sets no session cookie - so a `qr_id` copied out of a log, a `Referer`
/// or browser history cannot be exchanged for a session inside the 2-minute
/// window.
pub async fn qr_finalize_handler(
    Path(qr_id): Path<String>,
    State(state): State<QrAuthState>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    // Fail closed before revealing anything about the session's state: a
    // caller without the secret gets the same 403 whether the session is
    // pending, confirmed or absent.
    // The budget is spent before the secret check so that guessing secrets is
    // as expensive as guessing session ids.
    enforce(&state, &headers, "finalize", LIMIT_FINALIZE)?;

    let presented = cookie_value(&headers, "ms_qr_secret").unwrap_or_default();
    let secret_ok = !presented.is_empty()
        && AuthService::verify_pair_session_secret(&state.pool, &qr_id, &presented).await?;
    if !secret_ok {
        return Err(AppError::Forbidden(
            "This pairing session could not be verified. Refresh the QR code on this device and try again.".to_string(),
        ));
    }

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

    let cookie_val = AuthService::session_cookie(&session_id, &headers);

    let mut res = axum::response::Redirect::temporary("/").into_response();
    if let Ok(hdr_val) = header::HeaderValue::from_str(&cookie_val) {
        res.headers_mut().insert(header::SET_COOKIE, hdr_val);
    }
    // The secret has served its purpose; clear it with the same Path so the
    // browser treats this as the cookie that was set at create time.
    if let Ok(clear) =
        header::HeaderValue::from_str(&AuthService::clear_qr_secret_cookie(&qr_id, &headers))
    {
        res.headers_mut().append(header::SET_COOKIE, clear);
    }

    Ok(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limiter_allows_the_budget_then_refuses() {
        let limiter = RateLimiter::new();
        for _ in 0..3 {
            assert!(limiter.check("create", "10.0.0.1", 3).is_ok());
        }
        let retry = limiter.check("create", "10.0.0.1", 3).unwrap_err();
        assert!(
            (1..=60).contains(&retry),
            "retry-after must be a sensible delay, was {}",
            retry
        );

        // Another identity has its own budget...
        assert!(limiter.check("create", "10.0.0.2", 3).is_ok());
        // ...and so does another route for the same identity, so a burst of
        // status polls cannot spend the create budget.
        assert!(limiter.check("finalize", "10.0.0.1", 3).is_ok());
    }

    #[test]
    fn limiter_reopens_after_the_window() {
        let limiter = RateLimiter::new();
        let window = Duration::from_millis(40);
        assert!(limiter.check_window("wait", "10.0.0.1", 1, window).is_ok());
        assert!(limiter.check_window("wait", "10.0.0.1", 1, window).is_err());
        std::thread::sleep(Duration::from_millis(70));
        assert!(limiter.check_window("wait", "10.0.0.1", 1, window).is_ok());
    }

    #[test]
    fn sse_global_cap_refuses_beyond_the_pool() {
        let gate = SseGate::new(2);
        let _first = gate.try_acquire("10.0.0.1").expect("first within cap");
        let _second = gate.try_acquire("10.0.0.2").expect("second within cap");
        assert!(
            gate.try_acquire("10.0.0.3").is_none(),
            "the global pool must refuse a stream past its size"
        );
    }

    #[test]
    fn sse_cap_is_per_identity_and_released_on_drop() {
        // Global == per-identity so both gates agree for this test.
        let gate = SseGate::new(SSE_MAX_PER_IP);
        let held: Vec<SsePermit> = (0..SSE_MAX_PER_IP)
            .map(|_| {
                gate.try_acquire("10.0.0.1")
                    .expect("within the per-identity cap")
            })
            .collect();
        assert!(
            gate.try_acquire("10.0.0.1").is_none(),
            "one client must not hold more than its share"
        );
        assert!(
            gate.try_acquire("10.0.0.2").is_none(),
            "the global pool is exhausted too"
        );

        drop(held);
        assert!(
            gate.try_acquire("10.0.0.1").is_some(),
            "dropping a stream must return its permits - otherwise the pool leaks"
        );
    }

    #[test]
    fn client_identity_uses_the_last_forwarded_entry() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-for",
            "203.0.113.9, 198.51.100.7".parse().unwrap(),
        );
        assert_eq!(client_identity(&headers), "198.51.100.7");
        assert_eq!(client_identity(&HeaderMap::new()), "direct");
    }
}
