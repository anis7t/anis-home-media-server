use axum::{
    body::Body,
    extract::Request,
    http::{header, StatusCode},
    routing::{get, post},
    Json, Router,
};
use http_body_util::BodyExt;
use media_server_api::{
    config::AppConfig, create_app_full, db, services::system_service::SystemService,
};
use serde_json::json;
use std::net::SocketAddr;
use tower::ServiceExt;

async fn spawn_mock_flask() -> (SocketAddr, tokio::task::JoinHandle<()>) {
    let mock_app = Router::new()
        .route(
            "/poster/avatar.jpg",
            get(|| async {
                (
                    StatusCode::OK,
                    [(header::CONTENT_TYPE, "image/jpeg")],
                    vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10],
                )
            }),
        )
        .route(
            "/api/storage/audit",
            get(|| async {
                (
                    StatusCode::OK,
                    [(header::CONTENT_TYPE, "application/json")],
                    Json(json!({
                        "storage": { "pool": "ok" }
                    })),
                )
            }),
        )
        .route(
            "/api/storage/settings",
            post(|req: Request| async move {
                let pin = req
                    .headers()
                    .get("X-Admin-Pin")
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or("")
                    .to_string();
                let body_bytes = req.into_body().collect().await.unwrap().to_bytes();
                let parsed: serde_json::Value =
                    serde_json::from_slice(&body_bytes).unwrap_or(json!({}));
                (
                    StatusCode::OK,
                    [(header::CONTENT_TYPE, "application/json")],
                    Json(json!({
                        "received_pin": pin,
                        "echo": parsed
                    })),
                )
            }),
        )
        .route(
            "/auth/login",
            get(|| async {
                (
                    StatusCode::FOUND,
                    [
                        (header::LOCATION, "https://accounts.google.com/oauth"),
                        (
                            header::SET_COOKIE,
                            "session_token=secret123; HttpOnly; Path=/",
                        ),
                    ],
                    "Redirecting to Google...",
                )
            }),
        );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("Failed to bind mock listener");
    let addr = listener.local_addr().expect("Failed to get local addr");
    let handle = tokio::spawn(async move {
        axum::serve(listener, mock_app).await.ok();
    });

    (addr, handle)
}

async fn setup_test_app(upstream_url: Option<String>) -> Router {
    let config = AppConfig::from_env();
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();
    create_app_full(
        pool,
        system_service,
        config.media_roots,
        config.cache_dir,
        Some(config.static_dir),
        upstream_url,
    )
}

/// `/poster/*` is served natively as of Phase C1a, so it must NOT reach the
/// upstream any more. This replaced a test that asserted the opposite
/// (that the proxy forwarded it) when the proxy entry was removed.
///
/// The assertion is deliberately "not the upstream's answer": a mock that
/// returns 200 for everything would otherwise let a re-introduced proxy
/// entry pass unnoticed.
#[tokio::test]
async fn test_poster_is_not_proxied_to_flask() {
    let (addr, handle) = spawn_mock_flask().await;
    let upstream_url = format!("http://{}", addr);
    let app = setup_test_app(Some(upstream_url)).await;

    // No media root contains this file, so the native handler must 404.
    // If the proxy entry were still registered, the mock upstream would
    // answer 200 and this would fail.
    let req = axum::http::Request::builder()
        .uri("/poster/avatar.jpg")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "/poster must be answered natively, not forwarded to Flask"
    );

    handle.abort();
}

/// Phase C3a & C3b: all `/api/devices/*` routes are 100% native.
/// They must NOT reach the mock upstream.
#[tokio::test]
async fn test_device_routes_are_not_proxied() {
    let (addr, handle) = spawn_mock_flask().await;
    let upstream_url = format!("http://{}", addr);
    let app = setup_test_app(Some(upstream_url)).await;

    for uri in [
        "/api/devices/heartbeat",
        "/api/devices/client-hints",
        "/api/devices",
    ] {
        let req = if uri == "/api/devices" {
            axum::http::Request::builder()
                .method("GET")
                .uri(uri)
                .body(Body::empty())
                .unwrap()
        } else {
            axum::http::Request::builder()
                .method("POST")
                .uri(uri)
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap()
        };
        let mut req = req;
        let peer: std::net::SocketAddr = "127.0.0.1:5000".parse().unwrap();
        req.extensions_mut().insert(axum::extract::ConnectInfo(peer));

        let res = app.clone().oneshot(req).await.unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap_or_default();

        // The status alone cannot discriminate here: both the mock upstream
        // and the native handler answer 200. The mock echoes the request,
        // so its distinctive `echo` key is the reliable signal.
        assert!(
            json.get("echo").is_none(),
            "{} returned the upstream's echo, so it is still proxied",
            uri
        );
        assert_eq!(status, StatusCode::OK);
    }

    handle.abort();
}

/// Phase C1b: `/tmdb-poster/*` and `/tmdb-backdrop/*` are served natively, so
/// they must not reach the upstream. Same reasoning as the poster test: a
/// mock that answers 200 to everything would let a re-introduced proxy entry
/// pass unnoticed, so the assertion is "not the upstream's answer".
#[tokio::test]
async fn test_tmdb_artwork_is_not_proxied_to_flask() {
    let (addr, handle) = spawn_mock_flask().await;
    let upstream_url = format!("http://{}", addr);
    let app = setup_test_app(Some(upstream_url)).await;

    // An id with no database row: the native handler answers 404 without any
    // network access, whereas the proxy would return the mock's 200.
    for uri in ["/tmdb-poster/123456", "/tmdb-backdrop/123456"] {
        let req = axum::http::Request::builder()
            .uri(uri)
            .body(Body::empty())
            .unwrap();

        let res = app.clone().oneshot(req).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::NOT_FOUND,
            "{} must be answered natively, not forwarded to Flask",
            uri
        );
    }

    handle.abort();
}

#[tokio::test]
async fn test_proxy_forwards_api_storage() {
    let (addr, handle) = spawn_mock_flask().await;
    let upstream_url = format!("http://{}", addr);
    let app = setup_test_app(Some(upstream_url)).await;

    let req = axum::http::Request::builder()
        .uri("/api/storage/audit")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json_val: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json_val["storage"]["pool"], "ok");

    handle.abort();
}

#[tokio::test]
async fn test_proxy_forwards_headers_and_body_post() {
    let (addr, handle) = spawn_mock_flask().await;
    let upstream_url = format!("http://{}", addr);
    let app = setup_test_app(Some(upstream_url)).await;

    let req = axum::http::Request::builder()
        .method("POST")
        .uri("/api/storage/settings")
        .header("Content-Type", "application/json")
        .header("X-Admin-Pin", "not-a-real-pin")
        .body(Body::from(r#"{"ping":"hello"}"#))
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json_val: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json_val["received_pin"], "not-a-real-pin");
    assert_eq!(json_val["echo"]["ping"], "hello");

    handle.abort();
}

#[tokio::test]
async fn test_proxy_preserves_redirect_and_cookies() {
    let (addr, handle) = spawn_mock_flask().await;
    let upstream_url = format!("http://{}", addr);
    let app = setup_test_app(Some(upstream_url)).await;

    let req = axum::http::Request::builder()
        .uri("/auth/login")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::FOUND);

    let location = res
        .headers()
        .get(header::LOCATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert_eq!(location, "https://accounts.google.com/oauth");

    let cookie = res
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(cookie.contains("session_token=secret123"));

    handle.abort();
}

#[tokio::test]
async fn test_proxy_returns_502_on_unreachable_upstream() {
    // Port 59999 has no server running
    let app = setup_test_app(Some("http://127.0.0.1:59999".to_string())).await;

    let req = axum::http::Request::builder()
        .uri("/api/storage/audit")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_GATEWAY);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json_val: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json_val["error"], "Bad Gateway");
}

