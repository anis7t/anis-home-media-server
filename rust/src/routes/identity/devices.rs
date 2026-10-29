use crate::error::AppError;
use crate::services::audit_service::AuditService;
use crate::services::auth_service::{AuthService, ResolvedIdentity};
use crate::services::device_service::{ClientHints, ConnectionInfo, DeviceService, RequestFacts};
use axum::{
    body::Body,
    extract::{ConnectInfo, State},
    http::{header, HeaderMap, HeaderValue, Method, Response, StatusCode},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::PgPool;
use std::net::SocketAddr;
use std::sync::Arc;

use std::path::PathBuf;

#[derive(Clone)]
pub struct DeviceState {
    pub pool: Arc<PgPool>,
    pub media_roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ClientHintsBody {
    pub model: Option<String>,
    pub platform: Option<String>,
    #[serde(rename = "platformVersion")]
    pub platform_version: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct RenameDeviceBody {
    pub device_id: Option<String>,
    pub name: Option<String>,
    pub admin_pin: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct DeleteDeviceBody {
    pub device_id: Option<String>,
    pub admin_pin: Option<String>,
}

/// Read the cookie value for `name` from a raw `Cookie` header.
fn cookie_value(headers: &HeaderMap, name: &str) -> Option<String> {
    let raw = headers.get(header::COOKIE)?.to_str().ok()?;
    raw.split(';')
        .filter_map(|pair| pair.trim().split_once('='))
        .find(|(k, _)| k.trim() == name)
        .map(|(_, v)| v.trim().to_string())
}

/// Header value decoded the way Werkzeug decodes it: **latin-1**.
///
/// `HeaderValue::to_str()` only accepts visible ASCII, so a User-Agent
/// containing an obs-text byte (e.g. `café-tracker/1.0`) would fail to
/// decode and be treated as *absent*. Werkzeug decodes those bytes as
/// latin-1, so Flask hashes the real string and Rust hashed an empty one -
/// minting a different `device_id` and splitting that client into two rows.
///
/// Measured, not assumed: Flask matched the formula on 7/7 cases and Rust
/// on 6/7, failing exactly the latin-1 case. Every byte maps to the code
/// point of the same value, so ASCII behaviour is unchanged.
fn header_str(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .map(|v| v.as_bytes().iter().map(|&b| b as char).collect::<String>())
}

fn hints_from(headers: &HeaderMap) -> ClientHints {
    ClientHints {
        model: header_str(headers, "sec-ch-ua-model"),
        platform: header_str(headers, "sec-ch-ua-platform"),
        platform_version: header_str(headers, "sec-ch-ua-platform-version"),
        mobile: header_str(headers, "sec-ch-ua-mobile"),
    }
}

/// Everything needed to register this request, gathered once.
fn facts(
    headers: &HeaderMap,
    remote_addr: &str,
    user_agent: &str,
    hints: ClientHints,
) -> RequestFacts {
    RequestFacts {
        user_agent: user_agent.to_string(),
        hints,
        conn: ConnectionInfo {
            connection_type: String::new(),
            client_ip: String::new(),
            public_ip: None,
            is_cloudflare: false,
        },
    }
    .with_connection(DeviceService::classify_connection(
        header_str(headers, "cf-connecting-ip").as_deref(),
        header_str(headers, "cf-ray").as_deref(),
        &header_str(headers, "host").unwrap_or_default(),
        header_str(headers, "x-forwarded-for").as_deref(),
        remote_addr,
    ))
}

impl RequestFacts {
    fn with_connection(mut self, conn: ConnectionInfo) -> Self {
        self.conn = conn;
        self
    }
}

fn resolve_device_id(headers: &HeaderMap, remote_addr: &str, user_agent: &str) -> (String, bool) {
    let cookie = cookie_value(headers, "ms_device_id");
    let header = header_str(headers, "x-device-id");
    let ip = DeviceService::classify_connection(
        header_str(headers, "cf-connecting-ip").as_deref(),
        header_str(headers, "cf-ray").as_deref(),
        &header_str(headers, "host").unwrap_or_default(),
        header_str(headers, "x-forwarded-for").as_deref(),
        remote_addr,
    )
    .client_ip;
    DeviceService::get_or_create_device_id(cookie.as_deref(), header.as_deref(), &ip, user_agent)
}

/// Resolve the signed-in caller, and claim an unowned device for them.
///
/// Claim-on-first-authenticated-request: a device that has never been linked
/// to an account belongs to the first account that signs in from it. An
/// already-owned device is never reassigned here, so signing in as a different
/// account does not silently take over a shared browser's device (or, through
/// it, its watch history).
///
/// Returns the caller's identity for per-user scoping, or `None` when the
/// request is anonymous.
async fn resolve_and_claim(
    pool: &PgPool,
    headers: &HeaderMap,
    device_id: &str,
) -> Option<ResolvedIdentity> {
    let identity = AuthService::resolve_session_identity(pool, headers).await;
    if let Some(id) = identity.as_ref() {
        if id.user_id > 0 {
            DeviceService::claim_device_for_user(pool, device_id, id.user_id).await;
        }
    }
    identity
}

///
/// A known device is one UPDATE. An unknown one falls through to full
/// registration, so a first-contact client still records its telemetry
/// instead of appearing as a bare row.
///
/// `ConnectInfo` is taken directly and placed before the final extractor:
/// in axum 0.8 `Option<ConnectInfo<_>>` does not compile, because
/// `Option<T>` now requires `OptionalFromRequestParts`, which `ConnectInfo`
/// does not implement. The peer address is populated by
/// `into_make_service_with_connect_info` in `main.rs`; tests insert the same
/// extension onto the request.
pub async fn heartbeat_handler(
    State(state): State<DeviceState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    method: Method,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        return Ok(preflight());
    }
    let addr = peer.ip().to_string();
    let ua = header_str(&headers, "user-agent").unwrap_or_default();
    let (device_id, _) = resolve_device_id(&headers, &addr, &ua);

    let ctx = facts(&headers, &addr, &ua, hints_from(&headers));
    DeviceService::record_heartbeat(&state.pool, &device_id, &ctx).await;
    resolve_and_claim(&state.pool, &headers, &device_id).await;

    Ok(json_response(
        json!({ "success": true, "device_id": device_id }),
    ))
}

/// `POST /api/devices/client-hints`
pub async fn client_hints_handler(
    State(state): State<DeviceState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    method: Method,
    body: Option<Json<ClientHintsBody>>,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        return Ok(preflight());
    }
    let addr = peer.ip().to_string();
    let ua = header_str(&headers, "user-agent").unwrap_or_default();
    let (device_id, _) = resolve_device_id(&headers, &addr, &ua);

    let payload = body.map(|Json(b)| b).unwrap_or_default();
    let updated = DeviceService::update_client_hints(
        &state.pool,
        &device_id,
        payload.model.as_deref(),
        payload.platform.as_deref(),
        payload.platform_version.as_deref(),
    )
    .await;

    // The row must exist for a claim to land; a request that updated hints
    // always does, and an unknown device has nothing to claim.
    if updated {
        resolve_and_claim(&state.pool, &headers, &device_id).await;
    }

    Ok(json_response(
        json!({ "success": true, "updated": updated, "device_id": device_id }),
    ))
}

/// `GET /api/devices`
pub async fn list_devices_handler(
    State(state): State<DeviceState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    method: Method,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        return Ok(preflight());
    }
    let addr = peer.ip().to_string();
    let ua = header_str(&headers, "user-agent").unwrap_or_default();
    let (device_id, _) = resolve_device_id(&headers, &addr, &ua);

    // Keepalive/touch on request
    let ctx = facts(&headers, &addr, &ua, hints_from(&headers));
    DeviceService::record_heartbeat(&state.pool, &device_id, &ctx).await;

    // Claim-on-first-signed-in-request, and use the identity as the per-user
    // scope for the list and its embedded watch history.
    let identity = resolve_and_claim(&state.pool, &headers, &device_id).await;
    let caller_user_id = identity.as_ref().map(|i| i.user_id).filter(|uid| *uid > 0);

    let is_admin = crate::services::auth_service::AuthService::is_admin_authorized(
        &state.pool,
        &headers,
        None,
    )
    .await;

    let (devices, stats) = DeviceService::get_all_devices(
        &state.pool,
        Some(&device_id),
        caller_user_id,
        is_admin,
        &state.cache_dir,
        &state.media_roots,
    )
    .await?;

    Ok(json_response(json!({
        "devices": devices,
        "stats": stats,
        "current_device_id": device_id,
    })))
}

/// `POST /api/devices/rename`
pub async fn rename_device_handler(
    State(state): State<DeviceState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    method: Method,
    body: Option<Json<RenameDeviceBody>>,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        return Ok(preflight());
    }
    let addr = peer.ip().to_string();
    let ua = header_str(&headers, "user-agent").unwrap_or_default();
    let (current_device_id, _) = resolve_device_id(&headers, &addr, &ua);

    let payload = match body {
        Some(Json(b)) => b,
        None => {
            return Ok(json_response_with_status(
                StatusCode::BAD_REQUEST,
                json!({ "error": "device_id is required" }),
            ));
        }
    };

    let target_id = payload.device_id.unwrap_or_default().trim().to_string();
    if target_id.is_empty() {
        return Ok(json_response_with_status(
            StatusCode::BAD_REQUEST,
            json!({ "error": "device_id is required" }),
        ));
    }

    // The request comes from `current_device_id`; claim it for the signed-in
    // caller, then decide whether the *target* is theirs to rename.
    let identity = resolve_and_claim(&state.pool, &headers, &current_device_id).await;
    let caller_user_id = identity.as_ref().map(|i| i.user_id).filter(|uid| *uid > 0);

    let is_admin = crate::services::auth_service::AuthService::is_admin_authorized(
        &state.pool,
        &headers,
        payload.admin_pin.as_deref(),
    )
    .await;

    let owns_target = match caller_user_id {
        Some(uid) => DeviceService::device_owned_by(&state.pool, &target_id, uid).await,
        None => false,
    };

    if !is_admin && target_id != current_device_id && !owns_target {
        return Ok(json_response_with_status(
            StatusCode::FORBIDDEN,
            json!({ "error": "Unauthorized: You can only rename your current device or one you own." }),
        ));
    }

    DeviceService::rename_device(&state.pool, &target_id, payload.name.as_deref()).await?;

    let ip = AuditService::extract_client_ip(&headers);
    let (actor_type, actor_id) =
        AuditService::extract_actor(&state.pool, &headers, payload.admin_pin.as_deref()).await;
    AuditService::record_event(
        &state.pool,
        actor_type,
        &actor_id,
        "device_rename",
        Some("device"),
        Some(&target_id),
        Some(json!({ "new_name": payload.name })),
        ip.as_deref(),
    )
    .await;

    Ok(json_response(json!({ "success": true })))
}

/// `POST /api/devices/delete`
pub async fn delete_device_handler(
    State(state): State<DeviceState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    method: Method,
    body: Option<Json<DeleteDeviceBody>>,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        return Ok(preflight());
    }
    let addr = peer.ip().to_string();
    let ua = header_str(&headers, "user-agent").unwrap_or_default();
    let (current_device_id, _) = resolve_device_id(&headers, &addr, &ua);

    let payload = match body {
        Some(Json(b)) => b,
        None => {
            return Ok(json_response_with_status(
                StatusCode::BAD_REQUEST,
                json!({ "error": "device_id is required" }),
            ));
        }
    };

    let target_id = payload.device_id.unwrap_or_default().trim().to_string();
    if target_id.is_empty() {
        return Ok(json_response_with_status(
            StatusCode::BAD_REQUEST,
            json!({ "error": "device_id is required" }),
        ));
    }

    // The request comes from `current_device_id`; claim it for the signed-in
    // caller, then decide whether the *target* is theirs to remove.
    let identity = resolve_and_claim(&state.pool, &headers, &current_device_id).await;
    let caller_user_id = identity.as_ref().map(|i| i.user_id).filter(|uid| *uid > 0);

    let is_admin = crate::services::auth_service::AuthService::is_admin_authorized(
        &state.pool,
        &headers,
        payload.admin_pin.as_deref(),
    )
    .await;

    let owns_target = match caller_user_id {
        Some(uid) => DeviceService::device_owned_by(&state.pool, &target_id, uid).await,
        None => false,
    };

    if !is_admin && target_id != current_device_id && !owns_target {
        return Ok(json_response_with_status(
            StatusCode::FORBIDDEN,
            json!({ "error": "Unauthorized: You can only remove your current device or one you own." }),
        ));
    }

    DeviceService::delete_device(&state.pool, &target_id).await?;

    let ip = AuditService::extract_client_ip(&headers);
    let (actor_type, actor_id) =
        AuditService::extract_actor(&state.pool, &headers, payload.admin_pin.as_deref()).await;
    AuditService::record_event(
        &state.pool,
        actor_type,
        &actor_id,
        "device_delete",
        Some("device"),
        Some(&target_id),
        None,
        ip.as_deref(),
    )
    .await;

    let mut res = json_response(json!({ "success": true }));
    if cookie_value(&headers, "ms_device_id").as_deref() == Some(&target_id) {
        if let Ok(val) = HeaderValue::from_str("ms_device_id=; Max-Age=0; Path=/; SameSite=Lax") {
            res.headers_mut().insert(header::SET_COOKIE, val);
        }
    }

    Ok(res)
}

fn preflight() -> Response<Body> {
    let mut res = Response::new(Body::empty());
    *res.status_mut() = StatusCode::OK;
    let h = res.headers_mut();
    h.insert("access-control-allow-origin", HeaderValue::from_static("*"));
    h.insert(
        "access-control-allow-methods",
        HeaderValue::from_static("GET, POST, HEAD, OPTIONS"),
    );
    h.insert(
        "access-control-allow-headers",
        HeaderValue::from_static("Content-Type, X-Device-Id, X-Admin-Pin"),
    );
    res
}

fn json_response_with_status(status: StatusCode, value: Value) -> Response<Body> {
    let mut res = json_response(value);
    *res.status_mut() = status;
    res
}

fn json_response(value: Value) -> Response<Body> {
    let body = serde_json::to_string(&value).unwrap_or_else(|_| "{}".to_string());
    let mut res = Response::new(Body::from(body));
    res.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    res.headers_mut()
        .insert("access-control-allow-origin", HeaderValue::from_static("*"));
    res
}
