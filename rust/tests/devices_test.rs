//! Phase C3a: native device registration and keepalive.
//!
//! The rows this suite creates are removed in both setup and teardown, and
//! the device ids are namespaced so cleanup can never touch a real device.

use axum::{
    body::Body,
    extract::ConnectInfo,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    config::AppConfig,
    create_app,
    services::{device_service::DeviceService, system_service::SystemService},
};
use serde_json::Value;
use sqlx::PgPool;
use std::net::SocketAddr;
use tower::ServiceExt;

const TEST_PREFIX: &str = "dev_rustc3a_";
const UA_WINDOWS: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0 Safari/537.36";

/// Serialized because these tests share one table and a prefix-wide cleanup:
/// a sibling running in parallel would have its rows deleted mid-test, and
/// the final residue check would race against rows still being inserted.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn harness() -> (axum::Router, PgPool) {
    let config = AppConfig::from_env();
    let pool = media_server_api::db::create_test_pool(&config.database_url)
        .await
        .expect("pool");
    let app = create_app(
        pool.clone(),
        SystemService::new(),
        config.media_roots,
        config.cache_dir,
    );
    (app, pool)
}

async fn cleanup(pool: &PgPool) {
    let _ = sqlx::query("DELETE FROM devices WHERE device_id LIKE $1")
        .bind(format!("{}%", TEST_PREFIX))
        .execute(pool)
        .await;
}

/// Requests carry the peer address the way production does, via the
/// ConnectInfo extension that `into_make_service_with_connect_info` injects.
fn request(
    method: Method,
    uri: &str,
    device_id: Option<&str>,
    body: Option<&str>,
    user_agent: Option<&str>,
) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(id) = device_id {
        builder = builder.header("x-device-id", id);
    }
    if let Some(ua) = user_agent {
        builder = builder.header(header::USER_AGENT, ua);
    }
    // Flask reads the body with `get_json`, which likewise requires a JSON
    // content type; without it both engines see an empty payload.
    if body.is_some() {
        builder = builder.header(header::CONTENT_TYPE, "application/json");
    }
    let mut req = builder.body(Body::from(body.unwrap_or("").to_string())).unwrap();
    let peer: SocketAddr = "192.168.1.50:51000".parse().unwrap();
    req.extensions_mut().insert(ConnectInfo(peer));
    req
}

async fn call(app: &axum::Router, req: Request<Body>) -> (StatusCode, Value) {
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

#[tokio::test]
async fn test_heartbeat_registers_a_new_device_with_telemetry() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;
    let id = format!("{}hb", TEST_PREFIX);

    let (status, body) = call(
        &app,
        request(Method::POST, "/api/devices/heartbeat", Some(&id), None, Some(UA_WINDOWS)),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["success"], true);
    assert_eq!(body["device_id"], id.as_str());

    let row: Option<(String, Option<String>, Option<String>, Option<String>)> =
        sqlx::query_as("SELECT connection_type, device_name, browser, user_agent FROM devices WHERE device_id = $1")
            .bind(&id)
            .fetch_optional(&pool)
            .await
            .unwrap();

    let (conn_type, name, browser, ua) = row.expect("device row must exist");
    assert_eq!(
        conn_type, "Local Network (LAN)",
        "a 192.168.x peer is LAN, not localhost - this is why connect info is wired"
    );
    assert_eq!(name.as_deref(), Some("Windows PC"));
    assert_eq!(browser.as_deref(), Some("Chrome 120"));
    assert!(ua.is_some());

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_heartbeat_updates_last_seen_for_a_known_device() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;
    let id = format!("{}known", TEST_PREFIX);
    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, first_seen, last_seen) \
         VALUES ($1, 'Seeded', 'Desktop', 'Linux', CURRENT_TIMESTAMP - interval '2 hours', CURRENT_TIMESTAMP - interval '2 hours')",
    )
    .bind(&id)
    .execute(&pool)
    .await
    .unwrap();

    let before: chrono::DateTime<chrono::Utc> =
        sqlx::query_scalar("SELECT last_seen FROM devices WHERE device_id = $1")
            .bind(&id)
            .fetch_one(&pool)
            .await
            .unwrap();

    let (status, _) = call(
        &app,
        request(Method::POST, "/api/devices/heartbeat", Some(&id), None, Some(UA_WINDOWS)),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let after: chrono::DateTime<chrono::Utc> =
        sqlx::query_scalar("SELECT last_seen FROM devices WHERE device_id = $1")
            .bind(&id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(after > before, "heartbeat must advance last_seen");

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_client_hints_updates_a_known_device() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;
    let id = format!("{}ch", TEST_PREFIX);
    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, user_agent, first_seen, last_seen) \
         VALUES ($1, 'Android Smartphone', 'Mobile', 'Android 10', '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(&id)
    .execute(&pool)
    .await
    .unwrap();

    let body = r#"{"model":"SM-A536E","platform":"Android","platformVersion":"13.0.0"}"#;
    let (status, json) = call(
        &app,
        request(Method::POST, "/api/devices/client-hints", Some(&id), Some(body), None),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["success"], true);
    assert_eq!(json["updated"], true);
    assert_eq!(json["device_id"], id.as_str());

    let (name, os): (Option<String>, Option<String>) =
        sqlx::query_as("SELECT device_name, device_os FROM devices WHERE device_id = $1")
            .bind(&id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(name.as_deref(), Some("Samsung Galaxy A"));
    assert_eq!(os.as_deref(), Some("Android 13"));

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_client_hints_reports_not_updated_for_an_unknown_device() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    let (status, body) = call(
        &app,
        request(
            Method::POST,
            "/api/devices/client-hints",
            Some(&format!("{}ghost", TEST_PREFIX)),
            Some(r#"{"model":"SM-A536E"}"#),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["updated"], false, "no row means nothing was updated");
    assert_eq!(body["success"], true);
}

#[tokio::test]
async fn test_device_id_resolution_matches_python() {
    // Same three inputs the Python helper distinguishes.
    let (from_cookie, new1) = DeviceService::get_or_create_device_id(
        Some("dev_cookie_id"), None, "1.2.3.4", "ua",
    );
    assert_eq!(from_cookie, "dev_cookie_id");
    assert!(!new1);

    let (from_header, new2) = DeviceService::get_or_create_device_id(
        Some("not-a-device"), Some("dev_header_id"), "1.2.3.4", "ua",
    );
    assert_eq!(from_header, "dev_header_id", "a cookie without the dev_ prefix is ignored");
    assert!(!new2);

    let (hashed, is_new) = DeviceService::get_or_create_device_id(None, None, "1.2.3.4", "ua");
    assert!(is_new);
    assert!(hashed.starts_with("dev_"));
    assert_eq!(hashed.len(), 20);
}

#[tokio::test]
async fn test_heartbeat_accepts_get_like_flask() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;
    let id = format!("{}get", TEST_PREFIX);
    let (status, body) = call(
        &app,
        request(Method::GET, "/api/devices/heartbeat", Some(&id), None, Some(UA_WINDOWS)),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["device_id"], id.as_str());
    cleanup(&pool).await;
}

/// The defect the golden-value unit test cannot see.
///
/// The hash function was always right; header *decoding* was not.
/// `HeaderValue::to_str()` rejects obs-text bytes, so a latin-1 User-Agent
/// decoded as absent and hashed as the empty string. Flask matched 7/7,
/// Rust 6/7, failing exactly this case - which would have given that client
/// a second device row with no error anywhere.
#[tokio::test]
async fn test_non_ascii_user_agent_keeps_its_identity() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    // Sent as raw latin-1 bytes: `café-tracker/1.0`.
    let mut req = Request::builder()
        .method(Method::POST)
        .uri("/api/devices/heartbeat")
        .body(Body::empty())
        .unwrap();
    let peer: SocketAddr = "192.168.1.50:51000".parse().unwrap();
    req.extensions_mut().insert(ConnectInfo(peer));
    req.headers_mut()
        .append(header::USER_AGENT, header::HeaderValue::from_bytes(b"caf\xe9-tracker/1.0").unwrap());

    let (status, body) = call(&app, req).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body["device_id"], "dev_76dedd3b1b7ac988",
        "a latin-1 User-Agent must hash as itself, not as absent"
    );

    let stored: Option<String> =
        sqlx::query_scalar("SELECT user_agent FROM devices WHERE device_id = $1")
            .bind(body["device_id"].as_str().unwrap())
            .fetch_optional(&pool)
            .await
            .unwrap();
    assert_eq!(stored.as_deref(), Some("caf\u{e9}-tracker/1.0"));

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_suite_leaves_no_test_devices() {
    let _serial = SERIAL.lock().await;
    let (_app, pool) = harness().await;
    cleanup(&pool).await;
    let remaining: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM devices WHERE device_id LIKE $1",
    )
    .bind(format!("{}%", TEST_PREFIX))
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(remaining, 0, "devices table must retain no test rows");
    let _ = header::CONTENT_TYPE;
}