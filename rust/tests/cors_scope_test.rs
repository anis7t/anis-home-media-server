//! Phase C4-pre: receiver CORS is scoped to `/media/` and `/hls/`, and
//! `/api/*` is not readable from another origin.
//!
//! Both directions are load-bearing, and they fail in opposite ways. Too
//! permissive and the library, device fleet and host telemetry become
//! readable by any page the user visits, while the preflight stops blocking
//! cross-origin writes to the admin and storage endpoints. Too strict and a
//! cast receiver fetches the HLS manifest, requests **no segment**, and the
//! session ends silently - the documented "MP4 casts, MKV does not" failure,
//! which produces no error this server can see.

use axum::{
    body::Body,
    http::{header, Method, Request, StatusCode},
};
use media_server_api::{create_app, services::system_service::SystemService};
use tower::ServiceExt;

async fn app() -> axum::Router {
    let config = media_server_api::test_support::test_config().await;
    let pool = media_server_api::db::create_test_pool(&config.database_url)
        .await
        .expect("pool");
    create_app(
        pool,
        SystemService::new(),
        config.media_roots,
        config.cache_dir,
    )
}

fn req(method: Method, uri: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header(header::ORIGIN, "https://evil.example")
        .body(Body::empty())
        .unwrap()
}

fn acao(res: &axum::response::Response) -> Option<String> {
    res.headers()
        .get(header::ACCESS_CONTROL_ALLOW_ORIGIN)
        .map(|v| v.to_str().unwrap().to_string())
}

#[tokio::test]
async fn media_paths_are_readable_by_a_receiver() {
    let app = app().await;
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/media/no-such-file.mkv"))
        .await
        .unwrap();
    assert_eq!(
        acao(&res).as_deref(),
        Some("*"),
        "a receiver fetching /media/ cross-origin must be allowed, even on a 404"
    );
}

#[tokio::test]
async fn hls_paths_are_readable_by_a_receiver() {
    let app = app().await;
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/hls/no-such-file/playlist.m3u8"))
        .await
        .unwrap();
    assert_eq!(acao(&res).as_deref(), Some("*"));
}

#[tokio::test]
async fn receiver_preflight_advertises_range_because_it_is_not_safelisted() {
    let app = app().await;
    for path in ["/media/x.mkv", "/hls/x/playlist.m3u8"] {
        let res = app.clone().oneshot(req(Method::OPTIONS, path)).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK, "{}", path);
        assert_eq!(acao(&res).as_deref(), Some("*"), "{}", path);
        let methods = res
            .headers()
            .get(header::ACCESS_CONTROL_ALLOW_METHODS)
            .unwrap()
            .to_str()
            .unwrap();
        assert!(methods.contains("GET") && methods.contains("HEAD") && methods.contains("OPTIONS"));
        let allowed = res
            .headers()
            .get(header::ACCESS_CONTROL_ALLOW_HEADERS)
            .unwrap()
            .to_str()
            .unwrap();
        assert!(
            allowed.contains("Range"),
            "{}: a loader sending Range preflights, and without Range in the allow list the \
             receiver fetches the playlist and then no segment",
            path
        );
        let exposed = res
            .headers()
            .get(header::ACCESS_CONTROL_EXPOSE_HEADERS)
            .unwrap()
            .to_str()
            .unwrap();
        assert!(exposed.contains("Content-Range"), "{}", path);
        assert_eq!(
            res.headers()
                .get("cross-origin-resource-policy")
                .map(|v| v.to_str().unwrap()),
            Some("cross-origin"),
            "{}",
            path
        );
    }
}

#[tokio::test]
async fn api_paths_are_not_readable_cross_origin() {
    let app = app().await;
    for path in [
        "/api/movies",
        "/api/system-status",
        "/api/devices",
        "/api/cast/devices",
    ] {
        let res = app.clone().oneshot(req(Method::GET, path)).await.unwrap();
        assert_eq!(
            acao(&res),
            None,
            "{} must not advertise a readable cross-origin response: that leaks the library \
             and the device fleet, and the failing preflight is what stops cross-origin writes \
             to /api/scan, /api/storage/* and /api/admin*",
            path
        );
    }
}

#[tokio::test]
async fn api_preflight_fails_so_the_browser_never_sends_the_write() {
    let app = app().await;
    for path in ["/api/scan", "/api/storage/audit", "/api/admin/purge-cache"] {
        let res = app.clone().oneshot(req(Method::OPTIONS, path)).await.unwrap();
        assert_eq!(
            acao(&res),
            None,
            "{}: without an ACAO the preflight fails and the browser never issues the request",
            path
        );
    }
}