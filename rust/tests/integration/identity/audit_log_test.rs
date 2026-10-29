use axum::{
    body::Body,
    extract::Request,
    http::{header, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app_full, db, services::system_service::SystemService};
use serde_json::{json, Value};
use sqlx::{PgPool, Row};
use std::fs;
use std::path::PathBuf;
use tower::ServiceExt;

const TEST_ADMIN_PIN: &str = "97531";

struct TestContext {
    app: axum::Router,
    pool: PgPool,
    temp_dir: PathBuf,
}

impl TestContext {
    async fn new() -> Self {
        dotenvy::dotenv().ok();
        let config = media_server_api::test_support::test_config().await;
        let pool = db::create_pool(&config.database_url)
            .await
            .expect("Failed to connect to test db");

        let temp_dir = std::env::temp_dir().join(format!("ms_audit_test_{}", std::process::id()));
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

        // Ensure baseline admin PIN exists
        let _ = sqlx::query(
            "INSERT INTO settings (key, value) VALUES ('admin_pin', $1) ON CONFLICT (key) DO UPDATE SET value = $1",
        )
        .bind(TEST_ADMIN_PIN)
        .execute(&pool)
        .await;

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

async fn create_test_admin_session(pool: &PgPool, session_id: &str) -> String {
    let user_row = sqlx::query(
        r#"
        INSERT INTO users (google_sub, email, name, role, created_at, last_login_at)
        VALUES ($1, 'admin_auditor@test.local', 'Admin Auditor', 'admin', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (google_sub) DO UPDATE SET role = 'admin'
        RETURNING id
        "#,
    )
    .bind(format!("sub_{}", session_id))
    .fetch_one(pool)
    .await
    .unwrap();

    let user_id: i64 = user_row.get("id");

    sqlx::query(
        r#"
        INSERT INTO sessions (id, user_id, email, role, expires_at)
        VALUES ($1, $2, 'admin_auditor@test.local', 'admin', CURRENT_TIMESTAMP + INTERVAL '1 hour')
        ON CONFLICT (id) DO UPDATE SET role = 'admin', expires_at = CURRENT_TIMESTAMP + INTERVAL '1 hour'
        "#,
    )
    .bind(session_id)
    .bind(user_id)
    .execute(pool)
    .await
    .unwrap();

    session_id.to_string()
}

#[tokio::test]
async fn test_audit_logs_unauthorized_for_guests() {
    let ctx = TestContext::new().await;

    let req = Request::builder()
        .method("GET")
        .uri("/api/admin/audit-logs")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_audit_logs_query_with_admin_pin() {
    let ctx = TestContext::new().await;

    let req = Request::builder()
        .method("GET")
        .uri("/api/admin/audit-logs")
        .header("X-Admin-Pin", TEST_ADMIN_PIN)
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&bytes).unwrap();
    assert!(json.get("logs").is_some());
    assert!(json.get("total").is_some());
}

#[tokio::test]
async fn test_audit_logs_query_with_admin_session() {
    let ctx = TestContext::new().await;
    let sess_id = "sess_audit_query_test";
    create_test_admin_session(&ctx.pool, sess_id).await;

    let req = Request::builder()
        .method("GET")
        .uri("/api/admin/audit-logs")
        .header(header::COOKIE, format!("session_token={}", sess_id))
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&bytes).unwrap();
    assert!(json.get("logs").is_some());
}

#[tokio::test]
async fn test_admin_pin_change_creates_audit_record() {
    let ctx = TestContext::new().await;
    let sess_id = "sess_audit_pin_rot_test";
    create_test_admin_session(&ctx.pool, sess_id).await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/pin")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::COOKIE, format!("session_token={}", sess_id))
        .body(Body::from(
            json!({
                "current_pin": TEST_ADMIN_PIN,
                "new_pin": TEST_ADMIN_PIN
            })
            .to_string(),
        ))
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify audit log record exists
    let row = sqlx::query(
        r#"
        SELECT action, target_type, target_id
        FROM audit_logs
        WHERE action = 'pin_change' AND target_id = 'admin_pin'
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )
    .fetch_optional(&ctx.pool)
    .await
    .unwrap();

    assert!(row.is_some(), "Expected audit log record for pin_change");
}

#[tokio::test]
async fn test_device_mutations_create_audit_records() {
    let ctx = TestContext::new().await;
    let sess_id = "sess_audit_dev_test";
    create_test_admin_session(&ctx.pool, sess_id).await;

    let test_device_id = "test-device-audit-01";
    // Seed device with valid schema columns (custom_name)
    sqlx::query(
        r#"
        INSERT INTO devices (device_id, custom_name, first_seen, last_seen)
        VALUES ($1, 'Original Name', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (device_id) DO NOTHING
        "#,
    )
    .bind(test_device_id)
    .execute(&ctx.pool)
    .await
    .unwrap();

    // 1. Rename device
    let mut req = Request::builder()
        .method("POST")
        .uri("/api/devices/rename")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::COOKIE, format!("session_token={}", sess_id))
        .body(Body::from(
            json!({
                "device_id": test_device_id,
                "name": "Renamed Device"
            })
            .to_string(),
        ))
        .unwrap();
    req.extensions_mut().insert(axum::extract::ConnectInfo(
        "192.168.1.50:51000"
            .parse::<std::net::SocketAddr>()
            .unwrap(),
    ));

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify rename audit log
    let rename_log = sqlx::query(
        r#"
        SELECT action, target_type, target_id, details
        FROM audit_logs
        WHERE action = 'device_rename' AND target_id = $1
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )
    .bind(test_device_id)
    .fetch_optional(&ctx.pool)
    .await
    .unwrap();

    assert!(rename_log.is_some(), "Expected audit log for device_rename");

    // 2. Delete device
    let mut req = Request::builder()
        .method("POST")
        .uri("/api/devices/delete")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::COOKIE, format!("session_token={}", sess_id))
        .body(Body::from(
            json!({
                "device_id": test_device_id
            })
            .to_string(),
        ))
        .unwrap();
    req.extensions_mut().insert(axum::extract::ConnectInfo(
        "192.168.1.50:51000"
            .parse::<std::net::SocketAddr>()
            .unwrap(),
    ));

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify delete audit log
    let delete_log = sqlx::query(
        r#"
        SELECT action, target_type, target_id
        FROM audit_logs
        WHERE action = 'device_delete' AND target_id = $1
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )
    .bind(test_device_id)
    .fetch_optional(&ctx.pool)
    .await
    .unwrap();

    assert!(delete_log.is_some(), "Expected audit log for device_delete");
}

#[tokio::test]
async fn test_allowlist_update_creates_audit_record() {
    let ctx = TestContext::new().await;
    let sess_id = "sess_audit_allowlist_test";
    create_test_admin_session(&ctx.pool, sess_id).await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/auth/allowlist")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::COOKIE, format!("session_token={}", sess_id))
        .body(Body::from(
            json!({
                "emails": ["test_auditor_1@example.com", "test_auditor_2@example.com"]
            })
            .to_string(),
        ))
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify audit log for allowlist_update
    let log = sqlx::query(
        r#"
        SELECT action, target_type, target_id, details
        FROM audit_logs
        WHERE action = 'allowlist_update'
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )
    .fetch_optional(&ctx.pool)
    .await
    .unwrap();

    assert!(log.is_some(), "Expected audit log for allowlist_update");
}

#[tokio::test]
async fn test_audit_logs_filtering_and_pagination() {
    let ctx = TestContext::new().await;

    // Query with action filter
    let req = Request::builder()
        .method("GET")
        .uri("/api/admin/audit-logs?action=pin_change&limit=5&offset=0")
        .header("X-Admin-Pin", TEST_ADMIN_PIN)
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json.get("limit").and_then(|v| v.as_i64()), Some(5));
    assert_eq!(json.get("offset").and_then(|v| v.as_i64()), Some(0));
}
