use axum::{
    body::Body,
    extract::Request,
    http::{header, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app_full, db, services::system_service::SystemService};
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use tower::ServiceExt;

struct TestContext {
    app: axum::Router,
    pool: sqlx::PgPool,
    temp_dir: PathBuf,
}

impl TestContext {
    async fn new() -> Self {
        dotenvy::dotenv().ok();
        let config = media_server_api::test_support::test_config().await;
        let pool = db::create_pool(&config.database_url)
            .await
            .expect("Failed to connect to test db");

        let temp_dir = std::env::temp_dir().join(format!("ms_admin_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::create_dir_all(&temp_dir);

        let media_dir = temp_dir.join("media");
        let cache_dir = temp_dir.join("cache");
        fs::create_dir_all(&media_dir).unwrap();
        fs::create_dir_all(&cache_dir).unwrap();

        let system_service = SystemService::new();
        let app = create_app_full(
            pool.clone(),
            system_service,
            vec![media_dir],
            cache_dir,
            None,
            None,
        );

        Self {
            app,
            pool,
            temp_dir,
        }
    }
}

impl Drop for TestContext {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.temp_dir);
    }
}

#[tokio::test]
async fn test_admin_status_reports_has_pin_false_when_unset() {
    let ctx = TestContext::new().await;

    // Delete admin_pin from settings
    sqlx::query("DELETE FROM settings WHERE key = 'admin_pin'")
        .execute(&ctx.pool)
        .await
        .unwrap();

    let req = Request::builder()
        .method("GET")
        .uri("/api/admin/status")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(body["has_pin"], false);
    assert_eq!(body["is_admin"], false);
    assert!(body["user"].is_null());

    // Restore test admin pin
    let _ = sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '97531') ON CONFLICT (key) DO UPDATE SET value = '97531'"
    )
    .execute(&ctx.pool)
    .await;
}

#[tokio::test]
async fn test_admin_status_reports_has_pin_false_and_session_admin() {
    let ctx = TestContext::new().await;

    // Without credentials: has_pin is false, is_admin is false
    let req = Request::builder()
        .method("GET")
        .uri("/api/admin/status")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["has_pin"], false);
    assert_eq!(body["is_admin"], false);

    // With admin session: has_pin is false (retired), is_admin is true
    let sess_id = "sess_admin_status_test";
    let admin_email = "admin.status@example.com";
    let _ = sqlx::query(
        "INSERT INTO users (email, role, google_sub) VALUES ($1, 'admin', 'sub_admin_status') ON CONFLICT (email) DO UPDATE SET role = 'admin'"
    )
    .bind(admin_email)
    .execute(&ctx.pool)
    .await;
    let _ = sqlx::query(
        "INSERT INTO sessions (id, email, role, expires_at) VALUES ($1, $2, 'admin', CURRENT_TIMESTAMP + INTERVAL '1 day') ON CONFLICT (id) DO UPDATE SET email = $2, role = 'admin', expires_at = CURRENT_TIMESTAMP + INTERVAL '1 day'"
    )
    .bind(sess_id)
    .bind(admin_email)
    .execute(&ctx.pool)
    .await;

    let req_authed = Request::builder()
        .method("GET")
        .uri("/api/admin/status")
        .header(header::COOKIE, format!("session_token={}", sess_id))
        .body(Body::empty())
        .unwrap();

    let resp_authed = ctx.app.clone().oneshot(req_authed).await.unwrap();
    assert_eq!(resp_authed.status(), StatusCode::OK);

    let bytes = resp_authed.into_body().collect().await.unwrap().to_bytes();
    let body_authed: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body_authed["has_pin"], false);
    assert_eq!(body_authed["is_admin"], true);
    assert_eq!(body_authed["user"], admin_email);
}

#[tokio::test]
async fn test_verify_pin_success_variations() {
    let ctx = TestContext::new().await;

    // 1. Static PIN is retired: candidate static PIN fails 401 Unauthorized
    let req1 = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "pin": "97531" }).to_string()))
        .unwrap();
    let resp1 = ctx.app.clone().oneshot(req1).await.unwrap();
    assert_eq!(resp1.status(), StatusCode::UNAUTHORIZED);

    // 2. Admin session succeeds (200 OK)
    let sess_id = "sess_verify_var_admin";
    let admin_email = "admin.verify.var@example.com";
    let _ = sqlx::query(
        "INSERT INTO users (email, role, google_sub) VALUES ($1, 'admin', 'sub_verify_admin') ON CONFLICT (email) DO UPDATE SET role = 'admin'"
    )
    .bind(admin_email)
    .execute(&ctx.pool)
    .await;
    let _ = sqlx::query(
        "INSERT INTO sessions (id, email, role, expires_at) VALUES ($1, $2, 'admin', CURRENT_TIMESTAMP + INTERVAL '1 day') ON CONFLICT (id) DO UPDATE SET email = $2, role = 'admin', expires_at = CURRENT_TIMESTAMP + INTERVAL '1 day'"
    )
    .bind(sess_id)
    .bind(admin_email)
    .execute(&ctx.pool)
    .await;

    let req2 = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header(header::COOKIE, format!("session_token={}", sess_id))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from("{}"))
        .unwrap();
    let resp2 = ctx.app.clone().oneshot(req2).await.unwrap();
    assert_eq!(resp2.status(), StatusCode::OK);
    let body2: Value =
        serde_json::from_slice(&resp2.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body2["success"], true);
    assert_eq!(body2["admin"], true);
    assert_eq!(body2["method"], "google_session");
}

#[tokio::test]
async fn test_verify_pin_failure_cases() {
    let ctx = TestContext::new().await;

    let bad_payloads = vec![
        json!({ "pin": "0000" }),
        json!({ "pin": 1234 }),
        json!({ "pin": "" }),
        json!({ "pin": "    " }),
        json!({ "pin": Value::Null }),
        json!({}),
    ];

    for payload in bad_payloads {
        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/verify")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(payload.to_string()))
            .unwrap();
        let resp = ctx.app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
        let body: Value =
            serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
        assert_eq!(body["success"], false);
        assert_eq!(body["admin"], false);
    }
}

#[tokio::test]
async fn test_verify_pin_fails_closed_when_pin_unset() {
    let ctx = TestContext::new().await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "pin": "97531" }).to_string()))
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_admin_pin_rotation_lifecycle() {
    let ctx = TestContext::new().await;

    // POST /api/admin/pin is permanently retired and returns 410 Gone
    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/pin")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "new_pin": "8888" }).to_string()))
        .unwrap();
    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::GONE);
}
