use crate::error::AppError;
use crate::services::device_service::{
    ClientHints, ConnectionInfo, DeviceService, RequestFacts,
};
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

#[derive(Clone)]
pub struct DeviceState {
    pub pool: Arc<PgPool>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ClientHintsBody {
    pub model: Option<String>,
    pub platform: Option<String>,
    #[serde(rename = "platformVersion")]
    pub platform_version: Option<String>,
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
    DeviceService::get_or_create_device_id(
        cookie.as_deref(),
        header.as_deref(),
        &ip,
        user_agent,
    )
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

    Ok(json_response(json!({ "success": true, "device_id": device_id })))
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

    Ok(json_response(
        json!({ "success": true, "updated": updated, "device_id": device_id }),
    ))
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
        HeaderValue::from_static("Content-Type, X-Device-Id"),
    );
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