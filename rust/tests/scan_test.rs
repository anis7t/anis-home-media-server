use axum::{
    body::Body,
    http::{Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    config::AppConfig,
    create_app_full, db,
    services::system_service::SystemService,
};
use sqlx::PgPool;
use tower::ServiceExt;

static LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn setup_test_pool() -> (PgPool, axum::Router) {
    let config = AppConfig::from_env();
    let pool = db::create_test_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");

    let system_service = SystemService::new();
    let app = create_app_full(
        pool.clone(),
        system_service,
        config.media_roots,
        config.cache_dir,
        None,
        Some(config.flask_origin),
    );

    (pool, app)
}

#[tokio::test]
async fn test_get_scan_returns_ok_status() {
    let _guard = LOCK.lock().await;
    let (_pool, app) = setup_test_pool().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/api/scan")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(json.get("status").is_some());
    assert!(json.get("busy").is_some());
}

#[tokio::test]
async fn test_post_scan_without_admin_pin_returns_403() {
    let _guard = LOCK.lock().await;
    let (pool, app) = setup_test_pool().await;

    // Ensure admin_pin is removed so it fails closed
    let _ = sqlx::query("DELETE FROM settings WHERE key = 'admin_pin'")
        .execute(&pool)
        .await;

    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/scan")
        .header("content-type", "application/json")
        .body(Body::from("{}"))
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        json["error"],
        "Administrator verification required to trigger library scan."
    );
}

#[tokio::test]
async fn test_post_scan_rejects_query_string_pin() {
    let _guard = LOCK.lock().await;
    let (pool, app) = setup_test_pool().await;

    // Configure test pin in settings
    let test_pin = "scan_test_pin_9876";
    sqlx::query("INSERT INTO settings (key, value) VALUES ('admin_pin', $1) ON CONFLICT (key) DO UPDATE SET value = $1")
        .bind(test_pin)
        .execute(&pool)
        .await
        .unwrap();

    // Query string PIN must be rejected (AGENTS.md s4)
    let req = Request::builder()
        .method(Method::POST)
        .uri(format!("/api/scan?pin={}", test_pin))
        .header("content-type", "application/json")
        .body(Body::from("{}"))
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);

    let _ = sqlx::query("DELETE FROM settings WHERE key = 'admin_pin'")
        .execute(&pool)
        .await;
}

#[tokio::test]
async fn test_post_scan_with_valid_header_pin_succeeds() {
    let _guard = LOCK.lock().await;
    let (pool, app) = setup_test_pool().await;

    let test_pin = "scan_test_pin_1234";
    sqlx::query("INSERT INTO settings (key, value) VALUES ('admin_pin', $1) ON CONFLICT (key) DO UPDATE SET value = $1")
        .bind(test_pin)
        .execute(&pool)
        .await
        .unwrap();

    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/scan")
        .header("X-Admin-Pin", test_pin)
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["status"], "scanning");
    assert_eq!(json["busy"], true);

    let _ = sqlx::query("DELETE FROM settings WHERE key = 'admin_pin'")
        .execute(&pool)
        .await;
}

#[tokio::test]
async fn test_post_scan_with_valid_body_pin_succeeds() {
    let _guard = LOCK.lock().await;
    let (pool, app) = setup_test_pool().await;

    let test_pin = "scan_test_pin_5678";
    sqlx::query("INSERT INTO settings (key, value) VALUES ('admin_pin', $1) ON CONFLICT (key) DO UPDATE SET value = $1")
        .bind(test_pin)
        .execute(&pool)
        .await
        .unwrap();

    let payload = serde_json::json!({ "admin_pin": test_pin });
    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/scan")
        .header("content-type", "application/json")
        .body(Body::from(payload.to_string()))
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["status"], "scanning");

    let _ = sqlx::query("DELETE FROM settings WHERE key = 'admin_pin'")
        .execute(&pool)
        .await;
}
