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
async fn test_serves_spa_index_at_root() {
    let app = setup_test_app().await;

    let req = Request::builder().uri("/").body(Body::empty()).unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let content_type = res
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        content_type.starts_with("text/html"),
        "expected text/html, got: {}",
        content_type
    );

    let cache_control = res
        .headers()
        .get(header::CACHE_CONTROL)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        cache_control.contains("no-cache"),
        "expected no-cache, got: {}",
        cache_control
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let html = String::from_utf8_lossy(&bytes);
    assert!(
        html.contains("root") || html.contains("<!doctype html") || html.contains("<!DOCTYPE html"),
        "HTML body does not contain root div or doctype: {}",
        html
    );
}

#[tokio::test]
async fn test_client_side_routing_fallback() {
    let app = setup_test_app().await;

    for route in &["/manage", "/devices", "/manual", "/movie/sample.mp4"] {
        let req = Request::builder().uri(*route).body(Body::empty()).unwrap();

        let res = app.clone().oneshot(req).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::OK,
            "route {} did not return 200 OK",
            route
        );

        let content_type = res
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        assert!(
            content_type.starts_with("text/html"),
            "expected text/html for {}, got: {}",
            route,
            content_type
        );

        let cache_control = res
            .headers()
            .get(header::CACHE_CONTROL)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        assert!(
            cache_control.contains("no-cache"),
            "expected no-cache for {}, got: {}",
            route,
            cache_control
        );
    }
}

#[tokio::test]
async fn test_static_asset_serving_with_immutable_cache() {
    let app = setup_test_app().await;

    // Discover an actual compiled asset from web/dist/assets
    let config = media_server_api::test_support::test_config().await;
    let assets_dir = config.static_dir.join("assets");
    if let Ok(entries) = std::fs::read_dir(&assets_dir) {
        for entry in entries.flatten() {
            let file_name = entry.file_name().to_string_lossy().to_string();
            if file_name.ends_with(".js") || file_name.ends_with(".css") {
                let uri = format!("/assets/{}", file_name);
                let req = Request::builder().uri(&uri).body(Body::empty()).unwrap();

                let res = app.clone().oneshot(req).await.unwrap();
                assert_eq!(res.status(), StatusCode::OK);

                let cache_control = res
                    .headers()
                    .get(header::CACHE_CONTROL)
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or("");
                assert!(
                    cache_control.contains("immutable"),
                    "expected immutable cache for asset {}, got: {}",
                    file_name,
                    cache_control
                );
                return;
            }
        }
    }
}

#[tokio::test]
async fn test_api_endpoints_retain_precedence_over_spa() {
    let app = setup_test_app().await;

    let req = Request::builder()
        .uri("/api/health")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let content_type = res
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        content_type.starts_with("application/json"),
        "expected application/json for /api/health, got: {}",
        content_type
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["status"], "healthy");
}

#[tokio::test]
async fn test_missing_api_and_media_routes_return_404_json_not_html() {
    let app = setup_test_app().await;

    let routes = [
        "/api/nonexistent_route",
        "/media/missing_video.mp4",
        "/hls/missing_stream/playlist.m3u8",
        "/subtitles/missing_movie/missing_track.vtt",
        "/seek-preview/missing_movie/thumb_00001.jpg",
        "/preview-vtt/missing.vtt",
    ];

    for route in &routes {
        let req = Request::builder().uri(*route).body(Body::empty()).unwrap();

        let res = app.clone().oneshot(req).await.unwrap();
        assert!(
            res.status().is_client_error(),
            "route {} should return client error (4xx), got {}",
            route,
            res.status()
        );

        let content_type = res
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        assert!(
            !content_type.starts_with("text/html"),
            "route {} returned text/html instead of client error",
            route
        );
    }
}
