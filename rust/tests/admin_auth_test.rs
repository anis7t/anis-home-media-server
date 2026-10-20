use axum::{
    body::Body,
    extract::Request,
    http::{header, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    create_app_full, db, services::system_service::SystemService,
};
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
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '6361') ON CONFLICT (key) DO UPDATE SET value = '6361'"
    )
    .execute(&ctx.pool)
    .await;
}

#[tokio::test]
async fn test_admin_status_reports_has_pin_true_when_set() {
    let ctx = TestContext::new().await;

    sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '6361') ON CONFLICT (key) DO UPDATE SET value = '6361'"
    )
    .execute(&ctx.pool)
    .await
    .unwrap();

    // Without credentials
    let req = Request::builder()
        .method("GET")
        .uri("/api/admin/status")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["has_pin"], true);
    assert_eq!(body["is_admin"], false);

    // With X-Admin-Pin header
    let req_authed = Request::builder()
        .method("GET")
        .uri("/api/admin/status")
        .header("X-Admin-Pin", "6361")
        .body(Body::empty())
        .unwrap();

    let resp_authed = ctx.app.clone().oneshot(req_authed).await.unwrap();
    assert_eq!(resp_authed.status(), StatusCode::OK);

    let bytes = resp_authed.into_body().collect().await.unwrap().to_bytes();
    let body_authed: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body_authed["has_pin"], true);
    assert_eq!(body_authed["is_admin"], true);
}

#[tokio::test]
async fn test_verify_pin_success_variations() {
    let ctx = TestContext::new().await;

    sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '6361') ON CONFLICT (key) DO UPDATE SET value = '6361'"
    )
    .execute(&ctx.pool)
    .await
    .unwrap();

    // 1. Exact string {"pin": "6361"}
    let req1 = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "pin": "6361" }).to_string()))
        .unwrap();
    let resp1 = ctx.app.clone().oneshot(req1).await.unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);
    let body1: Value = serde_json::from_slice(&resp1.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body1["success"], true);
    assert_eq!(body1["admin"], true);
    assert_eq!(body1["method"], "pin");

    // 2. Numeric integer in JSON {"pin": 6361}
    let req2 = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "pin": 6361 }).to_string()))
        .unwrap();
    let resp2 = ctx.app.clone().oneshot(req2).await.unwrap();
    assert_eq!(resp2.status(), StatusCode::OK);
    let body2: Value = serde_json::from_slice(&resp2.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body2["success"], true);

    // 3. Alternate key 'admin_pin'
    let req3 = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "admin_pin": "6361" }).to_string()))
        .unwrap();
    let resp3 = ctx.app.clone().oneshot(req3).await.unwrap();
    assert_eq!(resp3.status(), StatusCode::OK);
    let body3: Value = serde_json::from_slice(&resp3.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body3["success"], true);

    // 4. Header X-Admin-Pin
    let req4 = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header("X-Admin-Pin", "6361")
        .body(Body::empty())
        .unwrap();
    let resp4 = ctx.app.clone().oneshot(req4).await.unwrap();
    assert_eq!(resp4.status(), StatusCode::OK);
    let body4: Value = serde_json::from_slice(&resp4.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body4["success"], true);

    // 5. Header with leading/trailing whitespace
    let req5 = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header("X-Admin-Pin", "  6361  ")
        .body(Body::empty())
        .unwrap();
    let resp5 = ctx.app.clone().oneshot(req5).await.unwrap();
    assert_eq!(resp5.status(), StatusCode::OK);
    let body5: Value = serde_json::from_slice(&resp5.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body5["success"], true);
}

#[tokio::test]
async fn test_verify_pin_failure_cases() {
    let ctx = TestContext::new().await;

    sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '6361') ON CONFLICT (key) DO UPDATE SET value = '6361'"
    )
    .execute(&ctx.pool)
    .await
    .unwrap();

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
        let body: Value = serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
        assert_eq!(body["success"], false);
        assert_eq!(body["admin"], false);
    }
}

#[tokio::test]
async fn test_verify_pin_fails_closed_when_pin_unset() {
    let ctx = TestContext::new().await;

    sqlx::query("DELETE FROM settings WHERE key = 'admin_pin'")
        .execute(&ctx.pool)
        .await
        .unwrap();

    // Even if caller submits candidate PIN "6361", an unset PIN means auth is closed.
    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "pin": "6361" }).to_string()))
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // Restore test admin pin
    let _ = sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '6361') ON CONFLICT (key) DO UPDATE SET value = '6361'"
    )
    .execute(&ctx.pool)
    .await;
}

#[tokio::test]
async fn test_admin_pin_rotation_lifecycle() {
    let ctx = TestContext::new().await;

    sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '6361') ON CONFLICT (key) DO UPDATE SET value = '6361'"
    )
    .execute(&ctx.pool)
    .await
    .unwrap();

    // A. Update without admin auth or PIN -> 403 Forbidden
    let req_unauth = Request::builder()
        .method("POST")
        .uri("/api/admin/pin")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "new_pin": "8888" }).to_string()))
        .unwrap();
    let resp_unauth = ctx.app.clone().oneshot(req_unauth).await.unwrap();
    assert_eq!(resp_unauth.status(), StatusCode::FORBIDDEN);

    // B. Update with short PIN (< 4 digits) -> 400 Bad Request
    let req_short = Request::builder()
        .method("POST")
        .uri("/api/admin/pin")
        .header("X-Admin-Pin", "6361")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "new_pin": "123" }).to_string()))
        .unwrap();
    let resp_short = ctx.app.clone().oneshot(req_short).await.unwrap();
    assert_eq!(resp_short.status(), StatusCode::BAD_REQUEST);

    // C. Update with valid new PIN -> 200 OK
    let req_valid = Request::builder()
        .method("POST")
        .uri("/api/admin/pin")
        .header("X-Admin-Pin", "6361")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "new_pin": "9999" }).to_string()))
        .unwrap();
    let resp_valid = ctx.app.clone().oneshot(req_valid).await.unwrap();
    assert_eq!(resp_valid.status(), StatusCode::OK);
    let body_valid: Value = serde_json::from_slice(&resp_valid.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body_valid["success"], true);

    // D. Old PIN '6361' is now rejected (401)
    let req_old = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "pin": "6361" }).to_string()))
        .unwrap();
    let resp_old = ctx.app.clone().oneshot(req_old).await.unwrap();
    assert_eq!(resp_old.status(), StatusCode::UNAUTHORIZED);

    // E. New PIN '9999' is accepted (200)
    let req_new = Request::builder()
        .method("POST")
        .uri("/api/admin/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "pin": "9999" }).to_string()))
        .unwrap();
    let resp_new = ctx.app.clone().oneshot(req_new).await.unwrap();
    assert_eq!(resp_new.status(), StatusCode::OK);

    // F. Restore original PIN '6361'
    let req_restore = Request::builder()
        .method("POST")
        .uri("/api/admin/pin")
        .header("X-Admin-Pin", "9999")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "new_pin": "6361" }).to_string()))
        .unwrap();
    let resp_restore = ctx.app.clone().oneshot(req_restore).await.unwrap();
    assert_eq!(resp_restore.status(), StatusCode::OK);
}
