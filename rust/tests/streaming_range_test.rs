use axum::{
    body::Body,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    create_app, db,
    services::system_service::SystemService,
};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use tower::ServiceExt;

use std::sync::atomic::{AtomicUsize, Ordering};

static TEST_COUNTER: AtomicUsize = AtomicUsize::new(1);

struct TestMediaHarness {
    app: axum::Router,
    test_dir: PathBuf,
    sample_data: Vec<u8>,
    nested_data: Vec<u8>,
}

impl Drop for TestMediaHarness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.test_dir);
    }
}

async fn setup_media_test() -> TestMediaHarness {
    let count = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let test_dir = std::env::temp_dir().join(format!("rust_media_test_{}_{}_{}", std::process::id(), now, count));
    fs::create_dir_all(&test_dir).expect("Failed to create test directory");

    // 10,000 bytes with predictable byte pattern
    let sample_data: Vec<u8> = (0..10_000).map(|i| (i % 256) as u8).collect();
    fs::write(test_dir.join("sample_stream.mp4"), &sample_data)
        .expect("Failed to write sample_stream.mp4");

    // Subdirectory with nested file
    let nested_dir = test_dir.join("nested");
    fs::create_dir_all(&nested_dir).expect("Failed to create nested directory");
    let nested_data: Vec<u8> = (0..2_048).map(|i| ((i + 42) % 256) as u8).collect();
    fs::write(nested_dir.join("nested_movie.mp4"), &nested_data)
        .expect("Failed to write nested_movie.mp4");

    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();

    let roots = vec![test_dir.clone()];
    let app = create_app(pool, system_service, roots, config.cache_dir);

    TestMediaHarness {
        app,
        test_dir,
        sample_data,
        nested_data,
    }
}

#[tokio::test]
async fn test_full_file_stream_200() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/media/sample_stream.mp4")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    assert_eq!(
        res.headers().get(header::ACCEPT_RANGES).unwrap(),
        "bytes"
    );
    assert_eq!(
        res.headers().get(header::CONTENT_LENGTH).unwrap(),
        "10000"
    );
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "video/mp4"
    );
    assert_eq!(
        res.headers().get("access-control-allow-origin").unwrap(),
        "*"
    );
    assert_eq!(
        res.headers().get("transfermode.dlna.org").unwrap(),
        "Streaming"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 10000);
    assert_eq!(bytes.as_ref(), &harness.sample_data[..]);
}

#[tokio::test]
async fn test_head_request_empty_body() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::HEAD)
        .uri("/media/sample_stream.mp4")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_LENGTH).unwrap(),
        "10000"
    );
    assert_eq!(
        res.headers().get(header::ACCEPT_RANGES).unwrap(),
        "bytes"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 0);
}

#[tokio::test]
async fn test_options_cors() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::OPTIONS)
        .uri("/media/sample_stream.mp4")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get("access-control-allow-origin").unwrap(),
        "*"
    );
    let allow_methods = res
        .headers()
        .get("access-control-allow-methods")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(allow_methods == "*" || allow_methods.contains("GET"));
}

#[tokio::test]
async fn test_range_initial_chunk() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/media/sample_stream.mp4")
        .header(header::RANGE, "bytes=0-1023")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        res.headers().get(header::CONTENT_RANGE).unwrap(),
        "bytes 0-1023/10000"
    );
    assert_eq!(
        res.headers().get(header::CONTENT_LENGTH).unwrap(),
        "1024"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 1024);
    assert_eq!(bytes.as_ref(), &harness.sample_data[0..1024]);
}

#[tokio::test]
async fn test_range_midstream_chunk() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/media/sample_stream.mp4")
        .header(header::RANGE, "bytes=1000-1999")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        res.headers().get(header::CONTENT_RANGE).unwrap(),
        "bytes 1000-1999/10000"
    );
    assert_eq!(
        res.headers().get(header::CONTENT_LENGTH).unwrap(),
        "1000"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 1000);
    assert_eq!(bytes.as_ref(), &harness.sample_data[1000..2000]);
}

#[tokio::test]
async fn test_range_open_ended() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/media/sample_stream.mp4")
        .header(header::RANGE, "bytes=9000-")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        res.headers().get(header::CONTENT_RANGE).unwrap(),
        "bytes 9000-9999/10000"
    );
    assert_eq!(
        res.headers().get(header::CONTENT_LENGTH).unwrap(),
        "1000"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 1000);
    assert_eq!(bytes.as_ref(), &harness.sample_data[9000..10000]);
}

#[tokio::test]
async fn test_range_suffix() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/media/sample_stream.mp4")
        .header(header::RANGE, "bytes=-500")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        res.headers().get(header::CONTENT_RANGE).unwrap(),
        "bytes 9500-9999/10000"
    );
    assert_eq!(
        res.headers().get(header::CONTENT_LENGTH).unwrap(),
        "500"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 500);
    assert_eq!(bytes.as_ref(), &harness.sample_data[9500..10000]);
}

#[tokio::test]
async fn test_range_unsatisfiable_416() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/media/sample_stream.mp4")
        .header(header::RANGE, "bytes=20000-")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::RANGE_NOT_SATISFIABLE);
    assert_eq!(
        res.headers().get(header::CONTENT_RANGE).unwrap(),
        "bytes */10000"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 0);
}

#[tokio::test]
async fn test_nested_subdirectory_stream() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/media/nested/nested_movie.mp4")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_LENGTH).unwrap(),
        "2048"
    );
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "video/mp4"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 2048);
    assert_eq!(bytes.as_ref(), &harness.nested_data[..]);
}

#[tokio::test]
async fn test_nonexistent_file_404() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/media/does_not_exist_2026.mp4")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_path_traversal_denied() {
    let harness = setup_media_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/media/..%2Fsecret.txt")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    // Either Axum rejects traversal directly with 400/404 or PathResolver returns 403 Forbidden
    assert!(
        res.status() == StatusCode::FORBIDDEN
            || res.status() == StatusCode::NOT_FOUND
            || res.status() == StatusCode::BAD_REQUEST
    );
}
