//! Phase C1a: native `/poster/{*filename}` artwork delivery.
//!
//! Isolation contract (AGENTS.md s9): all fixtures live in a temp directory
//! removed on drop; no database rows are created by this suite.

use axum::{
    body::Body,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app, services::system_service::SystemService};
use std::fs;
use std::path::PathBuf;
use tower::ServiceExt;

struct Fixture {
    app: axum::Router,
    media_root: PathBuf,
    cache_dir: PathBuf,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.media_root);
        let _ = fs::remove_dir_all(&self.cache_dir);
    }
}

/// Minimal valid PNG (1x1, transparent) so the bytes served are real image
/// bytes rather than an arbitrary fixture.
const PNG_1X1: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
];

async fn fixture(tag: &str) -> Fixture {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let media_root = std::env::temp_dir().join(format!(
        "rust_poster_media_{}_{}_{}",
        tag,
        std::process::id(),
        n
    ));
    let cache_dir = std::env::temp_dir().join(format!(
        "rust_poster_cache_{}_{}_{}",
        tag,
        std::process::id(),
        n
    ));
    fs::create_dir_all(&media_root).unwrap();
    fs::create_dir_all(&cache_dir).unwrap();
    fs::create_dir_all(media_root.join("posters")).unwrap();

    fs::write(media_root.join("posters/alpha.png"), PNG_1X1).unwrap();
    fs::write(media_root.join("alpha.jpg"), PNG_1X1).unwrap();
    fs::write(media_root.join("notes.txt"), b"not artwork").unwrap();
    fs::write(media_root.join("clip.mkv"), b"not artwork either").unwrap();

    let config = media_server_api::test_support::test_config().await;
    let pool = media_server_api::db::create_test_pool(&config.database_url)
        .await
        .expect("test pool");
    let app = create_app(
        pool,
        SystemService::new(),
        vec![media_root.clone()],
        cache_dir.clone(),
    );
    Fixture {
        app,
        media_root,
        cache_dir,
    }
}

#[tokio::test]
async fn test_resolve_local_image_finds_file_under_root() {
    let f = fixture("resolve").await;
    let roots = vec![f.media_root.clone()];
    let resolved = media_server_api::services::asset_service::AssetService::resolve_local_image(
        &roots,
        "posters/alpha.png",
    );
    assert!(
        resolved.is_ok(),
        "resolver rejected an existing png under the root: {:?}",
        resolved.err()
    );
    assert!(resolved.unwrap().is_file());
}

#[tokio::test]
async fn test_poster_serves_image_with_cache_validators() {
    let f = fixture("valid").await;
    let req = Request::builder()
        .method(Method::GET)
        .uri("/poster/posters/alpha.png")
        .body(Body::empty())
        .unwrap();
    let res = f.app.clone().oneshot(req).await.unwrap();

    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers()[header::CONTENT_TYPE], "image/png");
    assert_eq!(
        res.headers()[header::CACHE_CONTROL],
        "public, max-age=86400",
        "cache lifetime must match Flask's send_file(max_age=86400)"
    );
    assert!(res.headers().contains_key(header::ETAG));
    assert!(res.headers().contains_key(header::LAST_MODIFIED));
    assert_eq!(res.headers()[header::ACCESS_CONTROL_ALLOW_ORIGIN], "*");

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.as_ref(), PNG_1X1, "body must be the real file bytes");
}

#[tokio::test]
async fn test_poster_conditional_get_returns_304() {
    let f = fixture("conditional").await;
    let req = Request::builder()
        .method(Method::GET)
        .uri("/poster/posters/alpha.png")
        .body(Body::empty())
        .unwrap();
    let first = f.app.clone().oneshot(req).await.unwrap();
    let etag = first.headers()[header::ETAG].to_str().unwrap().to_string();
    let last_modified = first.headers()[header::LAST_MODIFIED]
        .to_str()
        .unwrap()
        .to_string();

    let req = Request::builder()
        .method(Method::GET)
        .uri("/poster/posters/alpha.png")
        .header(header::IF_NONE_MATCH, etag.clone())
        .body(Body::empty())
        .unwrap();
    let res = f.app.clone().oneshot(req).await.unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_MODIFIED,
        "If-None-Match with the current ETag must not re-send the body"
    );

    let req = Request::builder()
        .method(Method::GET)
        .uri("/poster/posters/alpha.png")
        .header(header::IF_MODIFIED_SINCE, last_modified)
        .body(Body::empty())
        .unwrap();
    let res = f.app.clone().oneshot(req).await.unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_MODIFIED,
        "If-Modified-Since with the current Last-Modified must 304"
    );
}

#[tokio::test]
async fn test_poster_rejects_non_image_extension() {
    let f = fixture("ext").await;
    for uri in ["/poster/notes.txt", "/poster/clip.mkv"] {
        let req = Request::builder()
            .method(Method::GET)
            .uri(uri)
            .body(Body::empty())
            .unwrap();
        let res = f.app.clone().oneshot(req).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::NOT_FOUND,
            "{} exists but is not artwork; must be 404, not a served file",
            uri
        );
    }
}

#[tokio::test]
async fn test_poster_rejects_directory_traversal() {
    let f = fixture("traversal").await;
    // Written outside the media root; must never be reachable.
    let secret = f
        .media_root
        .parent()
        .unwrap()
        .join(format!("rust_poster_secret_{}.png", std::process::id()));
    fs::write(&secret, b"secret").unwrap();

    for uri in [
        "/poster/../rust_poster_secret.png",
        "/poster/..%2Frust_poster_secret.png",
    ] {
        let req = Request::builder()
            .method(Method::GET)
            .uri(uri)
            .body(Body::empty())
            .unwrap();
        let res = f.app.clone().oneshot(req).await.unwrap();
        assert!(
            res.status() == StatusCode::NOT_FOUND
                || res.status() == StatusCode::FORBIDDEN
                || res.status() == StatusCode::BAD_REQUEST,
            "traversal {} returned {} - must be refused",
            uri,
            res.status()
        );
        let body = res.into_body().collect().await.unwrap().to_bytes();
        assert!(
            !body.as_ref().windows(6).any(|w| w == b"secret"),
            "traversal {} leaked file contents",
            uri
        );
    }

    let _ = fs::remove_file(&secret);
}

#[tokio::test]
async fn test_poster_missing_file_is_404_and_head_has_no_body() {
    let f = fixture("missing").await;
    let req = Request::builder()
        .method(Method::GET)
        .uri("/poster/does-not-exist.png")
        .body(Body::empty())
        .unwrap();
    assert_eq!(
        f.app.clone().oneshot(req).await.unwrap().status(),
        StatusCode::NOT_FOUND
    );

    let req = Request::builder()
        .method(Method::HEAD)
        .uri("/poster/posters/alpha.png")
        .body(Body::empty())
        .unwrap();
    let res = f.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert!(
        res.headers().contains_key(header::CONTENT_LENGTH),
        "HEAD must still advertise the length"
    );
    let body = res.into_body().collect().await.unwrap().to_bytes();
    assert!(body.is_empty(), "HEAD must not return a body");
}

#[tokio::test]
async fn test_poster_range_request_is_partial_content() {
    let f = fixture("range").await;
    let req = Request::builder()
        .method(Method::GET)
        .uri("/poster/posters/alpha.png")
        .header(header::RANGE, "bytes=0-9")
        .body(Body::empty())
        .unwrap();
    let res = f.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::PARTIAL_CONTENT);
    let body = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(body.len(), 10);
}

#[tokio::test]
async fn test_poster_options_preflight() {
    let f = fixture("options").await;
    let req = Request::builder()
        .method(Method::OPTIONS)
        .uri("/poster/posters/alpha.png")
        .body(Body::empty())
        .unwrap();
    let res = f.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers()[header::ACCESS_CONTROL_ALLOW_ORIGIN], "*");
}
