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
    create_app,
    services::{device_service::DeviceService, system_service::SystemService},
};
use serde_json::Value;
use sqlx::PgPool;
use std::net::SocketAddr;
use tower::ServiceExt;

const TEST_PREFIX: &str = "dev_rustc3a_";
/// Phase 2 ownership rows this suite owns. Users and sessions are namespaced
/// so cleanup can never touch a real account.
const TEST_USER_SUB_PREFIX: &str = "sub_dev_phase2_";
const TEST_SESSION_PREFIX: &str = "sess_dev_phase2_";
const UA_WINDOWS: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0 Safari/537.36";

/// Serialized because these tests share one table and a prefix-wide cleanup:
/// a sibling running in parallel would have its rows deleted mid-test, and
/// the final residue check would race against rows still being inserted.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn harness() -> (axum::Router, PgPool) {
    let config = media_server_api::test_support::test_config().await;
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
    let _ = sqlx::query("DELETE FROM device_watch_history WHERE device_id LIKE $1")
        .bind(format!("{}%", TEST_PREFIX))
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM devices WHERE device_id LIKE $1")
        .bind(format!("{}%", TEST_PREFIX))
        .execute(pool)
        .await;
    // Phase 2: sessions reference users, so they go first.
    let _ = sqlx::query("DELETE FROM sessions WHERE id LIKE $1")
        .bind(format!("{}%", TEST_SESSION_PREFIX))
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM users WHERE google_sub LIKE $1")
        .bind(format!("{}%", TEST_USER_SUB_PREFIX))
        .execute(pool)
        .await;
    let _ = sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '97531') ON CONFLICT (key) DO UPDATE SET value = '97531'"
    )
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
    request_with_headers(method, uri, device_id, body, user_agent, None, None)
}

fn request_with_headers(
    method: Method,
    uri: &str,
    device_id: Option<&str>,
    body: Option<&str>,
    user_agent: Option<&str>,
    admin_pin: Option<&str>,
    cookie: Option<&str>,
) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(id) = device_id {
        builder = builder.header("x-device-id", id);
    }
    if let Some(ua) = user_agent {
        builder = builder.header(header::USER_AGENT, ua);
    }
    if let Some(pin) = admin_pin {
        builder = builder.header("X-Admin-Pin", pin);
    }
    if let Some(c) = cookie {
        builder = builder.header(header::COOKIE, c);
    }
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

async fn call_full(app: &axum::Router, req: Request<Body>) -> (StatusCode, axum::http::HeaderMap, Value) {
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let headers = res.headers().clone();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    (status, headers, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

/// Create (or reuse) a viewer account and a live session for it.
/// Returns `(user_id, session_id)`. Both rows are namespaced.
async fn make_user_and_session(pool: &PgPool, suffix: &str, email: &str) -> (i64, String) {
    let sub = format!("{}{}", TEST_USER_SUB_PREFIX, suffix);
    let session_id = format!("{}{}", TEST_SESSION_PREFIX, suffix);

    sqlx::query(
        r#"
        INSERT INTO users (google_sub, email, name, role, created_at, last_login_at)
        VALUES ($1, $2, 'Phase 2 Test', 'viewer', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (google_sub) DO UPDATE SET email = EXCLUDED.email
        "#,
    )
    .bind(&sub)
    .bind(email)
    .execute(pool)
    .await
    .expect("upsert test user");

    let user_id: i64 = sqlx::query_scalar("SELECT id FROM users WHERE google_sub = $1")
        .bind(&sub)
        .fetch_one(pool)
        .await
        .expect("fetch test user id");

    sqlx::query(
        r#"
        INSERT INTO sessions (id, user_id, email, role, expires_at)
        VALUES ($1, $2, $3, 'viewer', CURRENT_TIMESTAMP + INTERVAL '30 days')
        ON CONFLICT (id) DO UPDATE SET
            user_id = EXCLUDED.user_id,
            email = EXCLUDED.email,
            expires_at = EXCLUDED.expires_at
        "#,
    )
    .bind(&session_id)
    .bind(user_id)
    .bind(email)
    .execute(pool)
    .await
    .expect("upsert test session");

    (user_id, session_id)
}

/// Insert a device row with an optional owner (`None` = unowned/guest).
async fn insert_device(pool: &PgPool, device_id: &str, owner: Option<i64>) {
    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, user_id, first_seen, last_seen) \
         VALUES ($1, 'Phase Two Device', 'Desktop', 'Linux', $2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(device_id)
    .bind(owner)
    .execute(pool)
    .await
    .expect("insert test device");
}

async fn insert_history(pool: &PgPool, device_id: &str, filename: &str) {
    sqlx::query(
        "INSERT INTO device_watch_history (device_id, filename, position, duration, completed) \
         VALUES ($1, $2, 12.5, 100.0, 0)",
    )
    .bind(device_id)
    .bind(filename)
    .execute(pool)
    .await
    .expect("insert test history");
}

fn session_cookie(session_id: &str) -> String {
    format!("session_token={}", session_id)
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
    let (app, _pool) = harness().await;
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
async fn test_get_devices_unauthenticated_returns_only_current_device() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let id1 = format!("{}dev1", TEST_PREFIX);
    let id2 = format!("{}dev2", TEST_PREFIX);

    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, first_seen, last_seen) \
         VALUES ($1, 'Dev One', 'Desktop', 'Linux', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP), \
                ($2, 'Dev Two', 'Mobile', 'Android', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(&id1)
    .bind(&id2)
    .execute(&pool)
    .await
    .unwrap();

    let (status, body) = call(
        &app,
        request(Method::GET, "/api/devices", Some(&id1), None, Some(UA_WINDOWS)),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    let devices = body["devices"].as_array().expect("devices array");
    assert_eq!(devices.len(), 1, "unauthenticated user must only see own device");
    assert_eq!(devices[0]["device_id"], id1.as_str());
    assert_eq!(devices[0]["is_current"], true);
    assert_eq!(body["current_device_id"], id1.as_str());
    assert_eq!(body["stats"]["total_devices"], 1);

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_get_devices_with_admin_pin_returns_all_devices() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    sqlx::query("INSERT INTO settings (key, value) VALUES ('admin_pin', '1234') ON CONFLICT (key) DO UPDATE SET value = '1234'")
        .execute(&pool)
        .await
        .unwrap();

    let id1 = format!("{}dev1", TEST_PREFIX);
    let id2 = format!("{}dev2", TEST_PREFIX);

    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, first_seen, last_seen) \
         VALUES ($1, 'Dev One', 'Desktop', 'Linux', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP), \
                ($2, 'Dev Two', 'Mobile', 'Android', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(&id1)
    .bind(&id2)
    .execute(&pool)
    .await
    .unwrap();

    let req = request_with_headers(
        Method::GET,
        "/api/devices",
        Some(&id1),
        None,
        Some(UA_WINDOWS),
        Some("1234"),
        None,
    );
    let (status, body) = call(&app, req).await;

    assert_eq!(status, StatusCode::OK);
    let devices = body["devices"].as_array().expect("devices array");
    assert!(devices.len() >= 2, "admin must see all devices");

    let d1 = devices.iter().find(|d| d["device_id"] == id1.as_str()).unwrap();
    assert_eq!(d1["is_current"], true);

    let d2 = devices.iter().find(|d| d["device_id"] == id2.as_str()).unwrap();
    assert_eq!(d2["is_current"], false);

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_rename_own_device_succeeds() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let id = format!("{}rename_own", TEST_PREFIX);
    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, first_seen, last_seen) \
         VALUES ($1, 'Original Name', 'Desktop', 'Linux', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(&id)
    .execute(&pool)
    .await
    .unwrap();

    let body_payload = serde_json::json!({
        "device_id": id,
        "name": "My Custom Laptop"
    })
    .to_string();

    let req = request(Method::POST, "/api/devices/rename", Some(&id), Some(&body_payload), Some(UA_WINDOWS));
    let (status, body) = call(&app, req).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["success"], true);

    let custom_name: Option<String> = sqlx::query_scalar("SELECT custom_name FROM devices WHERE device_id = $1")
        .bind(&id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(custom_name.as_deref(), Some("My Custom Laptop"));

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_rename_other_device_without_admin_is_forbidden_403() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let target_id = format!("{}rename_target", TEST_PREFIX);
    let caller_id = format!("{}rename_caller", TEST_PREFIX);

    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, first_seen, last_seen) \
         VALUES ($1, 'Target Original', 'Desktop', 'Linux', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP), \
                ($2, 'Caller Device', 'Mobile', 'Android', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(&target_id)
    .bind(&caller_id)
    .execute(&pool)
    .await
    .unwrap();

    let body_payload = serde_json::json!({
        "device_id": target_id,
        "name": "Hacked Name"
    })
    .to_string();

    let req = request(Method::POST, "/api/devices/rename", Some(&caller_id), Some(&body_payload), Some(UA_WINDOWS));
    let (status, body) = call(&app, req).await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(body["error"].as_str().unwrap().contains("Unauthorized"));

    let custom_name: Option<String> = sqlx::query_scalar("SELECT custom_name FROM devices WHERE device_id = $1")
        .bind(&target_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(custom_name, None);

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_rename_other_device_with_admin_pin_succeeds() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    sqlx::query("INSERT INTO settings (key, value) VALUES ('admin_pin', '1234') ON CONFLICT (key) DO UPDATE SET value = '1234'")
        .execute(&pool)
        .await
        .unwrap();

    let target_id = format!("{}rename_target", TEST_PREFIX);
    let caller_id = format!("{}rename_caller", TEST_PREFIX);

    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, first_seen, last_seen) \
         VALUES ($1, 'Target Original', 'Desktop', 'Linux', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(&target_id)
    .execute(&pool)
    .await
    .unwrap();

    let body_payload = serde_json::json!({
        "device_id": target_id,
        "name": "Admin Authorized Rename"
    })
    .to_string();

    let req = request_with_headers(
        Method::POST,
        "/api/devices/rename",
        Some(&caller_id),
        Some(&body_payload),
        Some(UA_WINDOWS),
        Some("1234"),
        None,
    );
    let (status, body) = call(&app, req).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["success"], true);

    let custom_name: Option<String> = sqlx::query_scalar("SELECT custom_name FROM devices WHERE device_id = $1")
        .bind(&target_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(custom_name.as_deref(), Some("Admin Authorized Rename"));

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_rename_missing_device_id_returns_400() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let body_payload = serde_json::json!({
        "device_id": "",
        "name": "New Name"
    })
    .to_string();

    let req = request(Method::POST, "/api/devices/rename", None, Some(&body_payload), Some(UA_WINDOWS));
    let (status, body) = call(&app, req).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "device_id is required");

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_delete_own_device_succeeds_and_unsets_cookie() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let id = format!("{}del_own", TEST_PREFIX);
    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, first_seen, last_seen) \
         VALUES ($1, 'To Delete', 'Desktop', 'Linux', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(&id)
    .execute(&pool)
    .await
    .unwrap();

    sqlx::query(
        "INSERT INTO device_watch_history (device_id, filename, position, duration, completed, last_watched) \
         VALUES ($1, 'sample.mkv', 120.0, 3600.0, 0, CURRENT_TIMESTAMP)",
    )
    .bind(&id)
    .execute(&pool)
    .await
    .unwrap();

    let body_payload = serde_json::json!({
        "device_id": id
    })
    .to_string();

    let cookie = format!("ms_device_id={}", id);
    let req = request_with_headers(
        Method::POST,
        "/api/devices/delete",
        Some(&id),
        Some(&body_payload),
        Some(UA_WINDOWS),
        None,
        Some(&cookie),
    );

    let (status, headers, body) = call_full(&app, req).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["success"], true);

    let set_cookie = headers.get(header::SET_COOKIE).and_then(|v| v.to_str().ok()).unwrap_or("");
    assert!(set_cookie.contains("ms_device_id=; Max-Age=0"), "cookie must be cleared on self delete");

    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE device_id = $1")
        .bind(&id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0);

    let h_count: i64 = sqlx::query_scalar("SELECT count(*) FROM device_watch_history WHERE device_id = $1")
        .bind(&id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(h_count, 0);

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_delete_other_device_without_admin_is_forbidden_403() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let target_id = format!("{}del_target", TEST_PREFIX);
    let caller_id = format!("{}del_caller", TEST_PREFIX);

    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, first_seen, last_seen) \
         VALUES ($1, 'Target Device', 'Desktop', 'Linux', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP), \
                ($2, 'Caller Device', 'Mobile', 'Android', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(&target_id)
    .bind(&caller_id)
    .execute(&pool)
    .await
    .unwrap();

    let body_payload = serde_json::json!({
        "device_id": target_id
    })
    .to_string();

    let req = request(Method::POST, "/api/devices/delete", Some(&caller_id), Some(&body_payload), Some(UA_WINDOWS));
    let (status, body) = call(&app, req).await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(body["error"].as_str().unwrap().contains("Unauthorized"));

    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE device_id = $1")
        .bind(&target_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 1, "target device must not be deleted");

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_delete_other_device_with_admin_pin_succeeds() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    sqlx::query("INSERT INTO settings (key, value) VALUES ('admin_pin', '1234') ON CONFLICT (key) DO UPDATE SET value = '1234'")
        .execute(&pool)
        .await
        .unwrap();

    let target_id = format!("{}del_target", TEST_PREFIX);
    let caller_id = format!("{}del_caller", TEST_PREFIX);

    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, first_seen, last_seen) \
         VALUES ($1, 'Target Device', 'Desktop', 'Linux', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP), \
                ($2, 'Caller Device', 'Mobile', 'Android', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
    )
    .bind(&target_id)
    .bind(&caller_id)
    .execute(&pool)
    .await
    .unwrap();

    let body_payload = serde_json::json!({
        "device_id": target_id
    })
    .to_string();

    let req = request_with_headers(
        Method::POST,
        "/api/devices/delete",
        Some(&caller_id),
        Some(&body_payload),
        Some(UA_WINDOWS),
        Some("1234"),
        None,
    );
    let (status, body) = call(&app, req).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["success"], true);

    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE device_id = $1")
        .bind(&target_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0, "device must be deleted by admin");

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

    let users: i64 = sqlx::query_scalar("SELECT count(*) FROM users WHERE google_sub LIKE $1")
        .bind(format!("{}%", TEST_USER_SUB_PREFIX))
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(users, 0, "users table must retain no Phase 2 test rows");

    let sessions: i64 = sqlx::query_scalar("SELECT count(*) FROM sessions WHERE id LIKE $1")
        .bind(format!("{}%", TEST_SESSION_PREFIX))
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(sessions, 0, "sessions table must retain no Phase 2 test rows");

    let _ = header::CONTENT_TYPE;
}

// --- Phase 2: per-user device ownership and watch-history scoping ---

#[tokio::test]
async fn test_signed_in_user_sees_only_their_devices_and_history() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let (alice_id, alice_session) =
        make_user_and_session(&pool, "alice", "alice@example.com").await;
    let (bob_id, _) = make_user_and_session(&pool, "bob", "bob@example.com").await;

    let alice_phone = format!("{}alice_phone", TEST_PREFIX);
    let alice_tv = format!("{}alice_tv", TEST_PREFIX);
    let bob_phone = format!("{}bob_phone", TEST_PREFIX);
    let unowned = format!("{}unowned", TEST_PREFIX);

    insert_device(&pool, &alice_phone, Some(alice_id)).await;
    insert_device(&pool, &alice_tv, Some(alice_id)).await;
    insert_device(&pool, &bob_phone, Some(bob_id)).await;
    insert_device(&pool, &unowned, None).await;

    insert_history(&pool, &alice_tv, "alice_movie.mp4").await;
    insert_history(&pool, &bob_phone, "bob_movie.mp4").await;

    let req = request_with_headers(
        Method::GET,
        "/api/devices",
        Some(&alice_phone),
        None,
        Some(UA_WINDOWS),
        None,
        Some(&session_cookie(&alice_session)),
    );
    let (status, body) = call(&app, req).await;

    assert_eq!(status, StatusCode::OK);
    let devices = body["devices"].as_array().expect("devices array");
    let ids: Vec<&str> = devices.iter().filter_map(|d| d["device_id"].as_str()).collect();

    assert!(ids.contains(&alice_phone.as_str()), "current device must be listed");
    assert!(ids.contains(&alice_tv.as_str()), "a device the user owns must be listed");
    assert!(!ids.contains(&bob_phone.as_str()), "another user's device must not be listed");
    assert!(!ids.contains(&unowned.as_str()), "an unowned device must not be listed");
    assert_eq!(devices.len(), 2, "exactly the user's own two devices");
    assert_eq!(body["stats"]["total_devices"], 2);

    let tv = devices
        .iter()
        .find(|d| d["device_id"] == alice_tv.as_str())
        .expect("owned TV");
    let tv_history = tv["watch_history"].as_array().expect("history array");
    assert_eq!(tv_history.len(), 1);
    assert_eq!(tv_history[0]["filename"], "alice_movie.mp4");

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_owner_can_rename_a_device_they_are_not_using() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let (alice_id, alice_session) =
        make_user_and_session(&pool, "alice_rename", "alice_rename@example.com").await;

    let alice_phone = format!("{}alice_r_phone", TEST_PREFIX);
    let alice_tv = format!("{}alice_r_tv", TEST_PREFIX);
    insert_device(&pool, &alice_phone, Some(alice_id)).await;
    insert_device(&pool, &alice_tv, Some(alice_id)).await;

    let payload =
        serde_json::json!({ "device_id": alice_tv, "name": "Living Room TV" }).to_string();
    let req = request_with_headers(
        Method::POST,
        "/api/devices/rename",
        Some(&alice_phone),
        Some(&payload),
        Some(UA_WINDOWS),
        None,
        Some(&session_cookie(&alice_session)),
    );
    let (status, body) = call(&app, req).await;

    assert_eq!(status, StatusCode::OK, "a user may rename a device they own");
    assert_eq!(body["success"], true);

    let name: Option<String> =
        sqlx::query_scalar("SELECT custom_name FROM devices WHERE device_id = $1")
            .bind(&alice_tv)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(name.as_deref(), Some("Living Room TV"));

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_other_user_cannot_rename_or_delete_my_device() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let (alice_id, _) = make_user_and_session(&pool, "alice_cross", "alice_cross@example.com").await;
    let (bob_id, bob_session) =
        make_user_and_session(&pool, "bob_cross", "bob_cross@example.com").await;

    let alice_tv = format!("{}alice_cross_tv", TEST_PREFIX);
    let bob_phone = format!("{}bob_cross_phone", TEST_PREFIX);
    insert_device(&pool, &alice_tv, Some(alice_id)).await;
    insert_device(&pool, &bob_phone, Some(bob_id)).await;

    // Bob tries to rename Alice's TV.
    let rename_payload =
        serde_json::json!({ "device_id": alice_tv, "name": "Not Yours" }).to_string();
    let req = request_with_headers(
        Method::POST,
        "/api/devices/rename",
        Some(&bob_phone),
        Some(&rename_payload),
        Some(UA_WINDOWS),
        None,
        Some(&session_cookie(&bob_session)),
    );
    let (status, _) = call(&app, req).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "renaming another user's device must be forbidden"
    );

    // Bob tries to delete Alice's TV.
    let delete_payload = serde_json::json!({ "device_id": alice_tv }).to_string();
    let req = request_with_headers(
        Method::POST,
        "/api/devices/delete",
        Some(&bob_phone),
        Some(&delete_payload),
        Some(UA_WINDOWS),
        None,
        Some(&session_cookie(&bob_session)),
    );
    let (status, _) = call(&app, req).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "deleting another user's device must be forbidden"
    );

    let still_there: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE device_id = $1")
        .bind(&alice_tv)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(still_there, 1, "the target device must survive a refused delete");

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_first_signed_in_request_claims_an_unowned_device_once() {
    let _serial = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let (alice_id, alice_session) =
        make_user_and_session(&pool, "alice_claim", "alice_claim@example.com").await;
    let (_bob_id, bob_session) =
        make_user_and_session(&pool, "bob_claim", "bob_claim@example.com").await;

    // A device nobody owns yet: a guest, or a client that predates Phase 2.
    let shared = format!("{}shared", TEST_PREFIX);
    insert_device(&pool, &shared, None).await;

    // Alice's first signed-in request claims it.
    let req = request_with_headers(
        Method::GET,
        "/api/devices",
        Some(&shared),
        None,
        Some(UA_WINDOWS),
        None,
        Some(&session_cookie(&alice_session)),
    );
    let (status, _) = call(&app, req).await;
    assert_eq!(status, StatusCode::OK);

    let owner: Option<i64> =
        sqlx::query_scalar("SELECT user_id FROM devices WHERE device_id = $1")
            .bind(&shared)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(owner, Some(alice_id), "first signed-in request must claim the device");

    // Alice watches something on it.
    insert_history(&pool, &shared, "alice_secret.mp4").await;

    // Bob signs in on the same physical device. Ownership must not transfer,
    // and Alice's history must not become readable through it.
    let req = request_with_headers(
        Method::GET,
        "/api/devices",
        Some(&shared),
        None,
        Some(UA_WINDOWS),
        None,
        Some(&session_cookie(&bob_session)),
    );
    let (status, body) = call(&app, req).await;
    assert_eq!(status, StatusCode::OK);

    let owner: Option<i64> =
        sqlx::query_scalar("SELECT user_id FROM devices WHERE device_id = $1")
            .bind(&shared)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(owner, Some(alice_id), "an already-owned device must never be reassigned");

    let listed = body["devices"]
        .as_array()
        .expect("devices array")
        .iter()
        .find(|d| d["device_id"] == shared.as_str())
        .expect("the current device is always listed");
    let history = listed["watch_history"].as_array().expect("history array");
    assert!(
        history.is_empty(),
        "a caller must not read another owner's history from a shared device"
    );

    cleanup(&pool).await;
}