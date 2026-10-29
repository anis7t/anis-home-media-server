use axum::{
    body::Body,
    http::{header, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app_with_static, db, services::system_service::SystemService};
use tower::ServiceExt;

async fn setup_test_app() -> axum::Router {
    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();
    create_app_with_static(
        pool,
        system_service,
        config.media_roots,
        config.cache_dir,
        Some(config.static_dir),
    )
}

#[tokio::test]
async fn test_app_update_production_manifest() {
    let app = setup_test_app().await;

    let req = Request::builder()
        .uri("/api/app/update?channel=production")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let content_type = res
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(content_type.contains("application/json"));

    let cache_control = res
        .headers()
        .get(header::CACHE_CONTROL)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(cache_control.contains("no-cache"));

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["channel"], "production");
    assert!(json["version"].is_string());
    assert!(json["versionCode"].is_number());
    assert!(json["sha256"].is_string());
}

#[tokio::test]
async fn test_app_update_invalid_channel() {
    let app = setup_test_app().await;

    let req = Request::builder()
        .uri("/api/app/update?channel=unknown_flavor")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_app_download_production_full_apk() {
    let app = setup_test_app().await;

    let req = Request::builder()
        .uri("/api/app/download?channel=production")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let content_type = res
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert_eq!(content_type, "application/vnd.android.package-archive");

    let disp = res
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(disp.contains("attachment; filename=\"media-server-production.apk\""));

    let accept_ranges = res
        .headers()
        .get(header::ACCEPT_RANGES)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert_eq!(accept_ranges, "bytes");

    let content_length: u64 = res
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    assert!(content_length > 10_000_000, "expected >10MB APK file");
}

#[tokio::test]
async fn test_app_download_production_range_request() {
    let app = setup_test_app().await;

    let req = Request::builder()
        .uri("/api/app/download?channel=production")
        .header(header::RANGE, "bytes=0-1023")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::PARTIAL_CONTENT);

    let content_range = res
        .headers()
        .get(header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(content_range.starts_with("bytes 0-1023/"));

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 1024);
}

#[tokio::test]
async fn test_app_download_invalid_channel() {
    let app = setup_test_app().await;

    let req = Request::builder()
        .uri("/api/app/download?channel=beta")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}
