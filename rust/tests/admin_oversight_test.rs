//! Access control Phase 3, Slice 3.1 — read model.
//!
//! Pins two rules:
//!  * `GET /api/devices` carries `owner` for an admin and **never** for a
//!    viewer (no other account's address in the payload), and
//!  * `GET /api/admin/users` lists accounts with device/history counts, under
//!    both the Admin PIN and an admin session, and refuses viewer/anonymous
//!    with a 403 rather than an empty list.
//!
//! Every row this suite touches is namespaced and removed in setup and
//! teardown. The tests serialise on `SERIAL` because the cleanup is
//! prefix-wide.

use axum::{
    body::Body,
    extract::ConnectInfo,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app, services::system_service::SystemService};
use serde_json::Value;
use sqlx::PgPool;
use std::net::SocketAddr;
use tower::ServiceExt;

const DEVICE_PREFIX: &str = "dev_oversight_";
const USER_SUB_PREFIX: &str = "sub_oversight_";
const SESSION_PREFIX: &str = "sess_oversight_";
const ADMIN_PIN: &str = "97531";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0 Safari/537.36";

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
        .bind(format!("{}%", DEVICE_PREFIX))
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM devices WHERE device_id LIKE $1")
        .bind(format!("{}%", DEVICE_PREFIX))
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM sessions WHERE id LIKE $1")
        .bind(format!("{}%", SESSION_PREFIX))
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM users WHERE google_sub LIKE $1")
        .bind(format!("{}%", USER_SUB_PREFIX))
        .execute(pool)
        .await;
    // The suite proves the PIN path, so it pins a known value.
    let _ = sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '97531') \
         ON CONFLICT (key) DO UPDATE SET value = '97531'",
    )
    .execute(pool)
    .await;
}

fn request(
    method: Method,
    uri: &str,
    device_id: Option<&str>,
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
    let mut req = builder.body(Body::from(String::new())).unwrap();
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

/// Create (or reuse) an account and a live session for it.
async fn make_user(pool: &PgPool, suffix: &str, email: &str, role: &str) -> (i64, String) {
    let sub = format!("{}{}", USER_SUB_PREFIX, suffix);
    let session_id = format!("{}{}", SESSION_PREFIX, suffix);

    sqlx::query(
        "INSERT INTO users (google_sub, email, name, role, created_at, last_login_at) \
         VALUES ($1, $2, 'Oversight Test', $3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) \
         ON CONFLICT (google_sub) DO UPDATE SET email = EXCLUDED.email, role = EXCLUDED.role",
    )
    .bind(&sub)
    .bind(email)
    .bind(role)
    .execute(pool)
    .await
    .expect("upsert test user");

    let user_id: i64 = sqlx::query_scalar("SELECT id FROM users WHERE google_sub = $1")
        .bind(&sub)
        .fetch_one(pool)
        .await
        .expect("fetch test user id");

    sqlx::query(
        "INSERT INTO sessions (id, user_id, email, role, expires_at) \
         VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP + INTERVAL '30 days') \
         ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id, \
             email = EXCLUDED.email, role = EXCLUDED.role, expires_at = EXCLUDED.expires_at",
    )
    .bind(&session_id)
    .bind(user_id)
    .bind(email)
    .bind(role)
    .execute(pool)
    .await
    .expect("upsert test session");

    (user_id, session_id)
}

async fn insert_device(pool: &PgPool, device_id: &str, owner: Option<i64>) {
    sqlx::query(
        "INSERT INTO devices (device_id, device_name, device_type, device_os, user_id, first_seen, last_seen) \
         VALUES ($1, 'Oversight device', 'Desktop', 'Windows', $2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) \
         ON CONFLICT (device_id) DO UPDATE SET user_id = EXCLUDED.user_id",
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
         VALUES ($1, $2, 10, 100, 0) \
         ON CONFLICT (device_id, filename) DO NOTHING",
    )
    .bind(device_id)
    .bind(filename)
    .execute(pool)
    .await
    .expect("insert test history");
}

#[tokio::test]
async fn test_device_owner_is_populated_for_admins_only() {
    let _guard = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let (alice_id, alice_session) =
        make_user(&pool, "alice", "oversight.alice@example.test", "viewer").await;
    insert_device(&pool, "dev_oversight_alice", Some(alice_id)).await;
    insert_device(&pool, "dev_oversight_guest", None).await;

    // Admin: attribution is present, and an unowned device says null.
    let (status, body) = call(
        &app,
        request(
            Method::GET,
            "/api/devices",
            Some("dev_oversight_admin_probe"),
            Some(UA),
            Some(ADMIN_PIN),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let devices = body["devices"].as_array().expect("devices array");
    let alice_device = devices
        .iter()
        .find(|d| d["device_id"] == "dev_oversight_alice")
        .expect("admin sees every device");
    assert_eq!(alice_device["owner"]["email"], "oversight.alice@example.test");
    assert_eq!(alice_device["owner"]["role"], "viewer");
    assert_eq!(alice_device["owner"]["id"], alice_id);
    let guest_device = devices
        .iter()
        .find(|d| d["device_id"] == "dev_oversight_guest")
        .expect("admin sees the unowned device");
    assert!(
        guest_device["owner"].is_null(),
        "an unowned device has a null owner"
    );

    // Viewer: own + current only, and no attribution whatsoever.
    let cookie = format!("session_token={}", alice_session);
    let (status, body) = call(
        &app,
        request(
            Method::GET,
            "/api/devices",
            Some("dev_oversight_viewer"),
            Some(UA),
            None,
            Some(&cookie),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let devices = body["devices"].as_array().expect("devices array");
    assert!(
        devices.iter().all(|d| d["device_id"] != "dev_oversight_guest"),
        "a viewer must not see an unrelated unowned device"
    );
    assert!(
        devices.iter().all(|d| d["owner"].is_null()),
        "a viewer must never receive owner attribution"
    );
    assert!(
        !body.to_string().contains("oversight.alice@example.test"),
        "the viewer payload must not contain another account's email"
    );

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_admin_users_lists_accounts_with_counts() {
    let _guard = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let (alice_id, _) = make_user(&pool, "alice", "oversight.alice@example.test", "viewer").await;
    let (bob_id, bob_session) =
        make_user(&pool, "bob", "oversight.bob@example.test", "admin").await;
    insert_device(&pool, "dev_oversight_alice", Some(alice_id)).await;
    insert_device(&pool, "dev_oversight_bob", Some(bob_id)).await;
    insert_history(&pool, "dev_oversight_alice", "oversight_one.mp4").await;
    insert_history(&pool, "dev_oversight_alice", "oversight_two.mp4").await;

    let (status, body) = call(
        &app,
        request(
            Method::GET,
            "/api/admin/users",
            None,
            Some(UA),
            Some(ADMIN_PIN),
            None,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let users = body["users"].as_array().expect("users array");

    let alice = users
        .iter()
        .find(|u| u["email"] == "oversight.alice@example.test")
        .expect("alice listed");
    assert_eq!(alice["role"], "viewer");
    assert_eq!(alice["device_count"].as_i64(), Some(1));
    assert_eq!(alice["history_count"].as_i64(), Some(2));
    assert!(alice["created_at"].is_string());

    let bob = users
        .iter()
        .find(|u| u["email"] == "oversight.bob@example.test")
        .expect("bob listed");
    assert_eq!(bob["role"], "admin");
    assert_eq!(bob["device_count"].as_i64(), Some(1));
    assert_eq!(bob["history_count"].as_i64(), Some(0));

    assert!(
        users.iter().all(|u| u.get("google_sub").is_none()),
        "the identity key must not be exposed"
    );

    // The admin-session path authorises the same route without a PIN.
    let cookie = format!("session_token={}", bob_session);
    let (status, body) = call(
        &app,
        request(
            Method::GET,
            "/api/admin/users",
            None,
            Some(UA),
            None,
            Some(&cookie),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["users"].as_array().map(|u| u.len()).unwrap_or(0) >= 2);

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_admin_users_refuses_viewer_and_anonymous() {
    let _guard = SERIAL.lock().await;
    let (app, pool) = harness().await;
    cleanup(&pool).await;

    let (_, viewer_session) =
        make_user(&pool, "viewer", "oversight.viewer@example.test", "viewer").await;
    let cookie = format!("session_token={}", viewer_session);

    let (status, body) = call(
        &app,
        request(
            Method::GET,
            "/api/admin/users",
            None,
            Some(UA),
            None,
            Some(&cookie),
        ),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "a viewer session must be refused, not shown an empty list"
    );
    assert!(body["error"].is_string());

    let (status, body) = call(
        &app,
        request(Method::GET, "/api/admin/users", None, Some(UA), None, None),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(body["error"].is_string());

    cleanup(&pool).await;
}

#[tokio::test]
async fn test_suite_leaves_no_oversight_residue() {
    let _guard = SERIAL.lock().await;
    let (_, pool) = harness().await;
    cleanup(&pool).await;

    let devices: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE device_id LIKE $1")
            .bind(format!("{}%", DEVICE_PREFIX))
            .fetch_one(&pool)
            .await
            .expect("device residue count");
    let users: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE google_sub LIKE $1")
        .bind(format!("{}%", USER_SUB_PREFIX))
        .fetch_one(&pool)
        .await
        .expect("user residue count");
    let sessions: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sessions WHERE id LIKE $1")
        .bind(format!("{}%", SESSION_PREFIX))
        .fetch_one(&pool)
        .await
        .expect("session residue count");

    assert_eq!(
        (devices, users, sessions),
        (0, 0, 0),
        "the oversight suite must leave no rows behind"
    );
}
