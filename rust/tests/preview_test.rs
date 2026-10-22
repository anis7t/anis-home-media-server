use axum::{
    body::Body,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    create_app, db,
    models::preview::SeekPreviewMetaResponse,
    services::{preview_service::PreviewService, system_service::SystemService},
};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use tower::ServiceExt;

static TEST_COUNTER: AtomicUsize = AtomicUsize::new(200);

struct TestPreviewHarness {
    app: axum::Router,
    test_dir: PathBuf,
    cache_dir: PathBuf,
    pool: sqlx::PgPool,
    test_filename: String,
}

impl TestPreviewHarness {
    pub async fn teardown(self) {
        let _ = sqlx::query("DELETE FROM progress WHERE filename = $1")
            .bind(&self.test_filename)
            .execute(&self.pool)
            .await;
        let _ = sqlx::query("DELETE FROM movies WHERE filename = $1")
            .bind(&self.test_filename)
            .execute(&self.pool)
            .await;
    }
}

impl Drop for TestPreviewHarness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.test_dir);
        let _ = fs::remove_dir_all(&self.cache_dir);
    }
}

async fn setup_preview_test() -> TestPreviewHarness {
    let count = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();

    let test_dir = std::env::temp_dir().join(format!("rust_prev_media_{}_{}_{}", std::process::id(), now, count));
    let cache_dir = std::env::temp_dir().join(format!("rust_prev_cache_{}_{}_{}", std::process::id(), now, count));
    fs::create_dir_all(&test_dir).expect("Failed to create media directory");
    fs::create_dir_all(&cache_dir).expect("Failed to create cache directory");

    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();

    let test_filename = format!("rust_test_movie_{}.mp4", count);

    // Clean up any lingering test rows
    let _ = sqlx::query("DELETE FROM progress WHERE filename LIKE 'rust_test_movie_%'")
        .execute(&pool)
        .await;
    let _ = sqlx::query("DELETE FROM movies WHERE filename LIKE 'rust_test_movie_%'")
        .execute(&pool)
        .await;

    // Insert movie and progress rows
    sqlx::query(
        "INSERT INTO movies (filename, title, runtime) VALUES ($1, $2, $3)",
    )
    .bind(&test_filename)
    .bind("Rust Test Movie")
    .bind(20) // 20 minutes
    .execute(&pool)
    .await
    .expect("Failed to insert test movie row");

    sqlx::query(
        "INSERT INTO progress (filename, position, duration) VALUES ($1, $2, $3)",
    )
    .bind(&test_filename)
    .bind(0.0)
    .bind(1200.0) // 1200 seconds
    .execute(&pool)
    .await
    .expect("Failed to insert test progress row");

    // Write dummy file to media directory
    let video_path = test_dir.join(&test_filename);
    fs::write(&video_path, b"dummy video file content").expect("Failed to write test video");

    let roots = vec![test_dir.clone()];
    let app = create_app(pool.clone(), system_service, roots, cache_dir.clone());

    TestPreviewHarness {
        app,
        test_dir,
        cache_dir,
        pool,
        test_filename,
    }
}

#[test]
fn test_preview_meta_calculation() {
    // Under 30 minutes (< 1800s) -> 5.0s interval
    let meta_short = PreviewService::calculate_meta(600.0, "short.mp4");
    assert_eq!(meta_short.duration, 600.0);
    assert_eq!(meta_short.interval, 5.0);
    assert_eq!(meta_short.count, 120);
    assert_eq!(meta_short.base_url, "/seek-preview/short.mp4");

    // Under 2 hours (< 7200s) -> 10.0s interval
    let meta_med = PreviewService::calculate_meta(3600.0, "med.mp4");
    assert_eq!(meta_med.duration, 3600.0);
    assert_eq!(meta_med.interval, 10.0);
    assert_eq!(meta_med.count, 360);

    // Over 2 hours (>= 7200s) -> 15.0s interval
    let meta_long = PreviewService::calculate_meta(7245.5, "long.mp4");
    assert_eq!(meta_long.duration, 7245.5);
    assert_eq!(meta_long.interval, 15.0);
    assert_eq!(meta_long.count, 484);
}

#[test]
fn test_preview_key_determinism() {
    let path = PathBuf::from("E:/MediaServer/tests/sample.mp4");
    let key1 = PreviewService::get_preview_key(&path);
    let key2 = PreviewService::get_preview_key(&path);
    assert_eq!(key1, key2);
    assert_eq!(key1.len(), 64); // SHA-256 hex is 64 characters
}

#[test]
fn test_generate_storyboard_vtt() {
    let meta = SeekPreviewMetaResponse {
        duration: 25.0,
        interval: 10.0,
        count: 3,
        base_url: "/seek-preview/test.mp4".to_string(),
    };
    let vtt = PreviewService::generate_storyboard_vtt(&meta, "test.mp4");

    assert!(vtt.starts_with("WEBVTT\n"));
    assert!(vtt.contains("00:00:00.000 --> 00:00:10.000"));
    assert!(vtt.contains("/seek-preview/test.mp4/thumb_00000.jpg"));
    assert!(vtt.contains("00:00:10.000 --> 00:00:20.000"));
    assert!(vtt.contains("/seek-preview/test.mp4/thumb_00001.jpg"));
    assert!(vtt.contains("00:00:20.000 --> 00:00:25.000"));
    assert!(vtt.contains("/seek-preview/test.mp4/thumb_00002.jpg"));
}

#[tokio::test]
async fn test_get_preview_meta_endpoint() {
    let harness = setup_preview_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri(format!("/api/seek-preview-meta/{}", harness.test_filename))
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let meta: SeekPreviewMetaResponse = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(meta.duration, 1200.0);
    assert_eq!(meta.interval, 5.0);
    assert_eq!(meta.count, 240);
    assert_eq!(
        meta.base_url,
        format!("/seek-preview/{}", harness.test_filename)
    );
    harness.teardown().await;
}

#[tokio::test]
async fn test_get_preview_thumb_cached_serving() {
    let harness = setup_preview_test().await;

    // Pre-populate thumbnail in cache directory
    let video_path = harness.test_dir.join(&harness.test_filename);
    let preview_dir = PreviewService::get_preview_dir(
        &video_path,
        &harness.cache_dir,
        &[harness.test_dir.clone()],
    );
    fs::create_dir_all(&preview_dir).unwrap();

    // Standard JPEG SOI marker + dummy payload
    let fake_jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46];
    let thumb_file = preview_dir.join("thumb_00000.jpg");
    fs::write(&thumb_file, &fake_jpeg).unwrap();

    let req = Request::builder()
        .method(Method::GET)
        .uri(format!(
            "/seek-preview/{}/thumb_00000.jpg",
            harness.test_filename
        ))
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "image/jpeg"
    );
    assert_eq!(
        res.headers().get(header::CONTENT_LENGTH).unwrap(),
        &fake_jpeg.len().to_string()
    );
    assert_eq!(
        res.headers().get("access-control-allow-origin").unwrap(),
        "*"
    );
    assert_eq!(
        res.headers().get("cross-origin-resource-policy").unwrap(),
        "cross-origin"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.as_ref(), fake_jpeg.as_slice());
    harness.teardown().await;
}

#[tokio::test]
async fn test_preview_thumb_head_and_options() {
    let harness = setup_preview_test().await;

    let video_path = harness.test_dir.join(&harness.test_filename);
    let preview_dir = PreviewService::get_preview_dir(
        &video_path,
        &harness.cache_dir,
        &[harness.test_dir.clone()],
    );
    fs::create_dir_all(&preview_dir).unwrap();
    let fake_jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0];
    fs::write(preview_dir.join("thumb_00001.jpg"), &fake_jpeg).unwrap();

    // Test HEAD
    let req_head = Request::builder()
        .method(Method::HEAD)
        .uri(format!(
            "/seek-preview/{}/thumb_00001.jpg",
            harness.test_filename
        ))
        .body(Body::empty())
        .unwrap();

    let res_head = harness.app.clone().oneshot(req_head).await.unwrap();
    assert_eq!(res_head.status(), StatusCode::OK);
    assert_eq!(
        res_head.headers().get(header::CONTENT_TYPE).unwrap(),
        "image/jpeg"
    );
    let bytes_head = res_head.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes_head.len(), 0);

    // Test OPTIONS
    let req_options = Request::builder()
        .method(Method::OPTIONS)
        .uri(format!(
            "/seek-preview/{}/thumb_00001.jpg",
            harness.test_filename
        ))
        .body(Body::empty())
        .unwrap();

    let res_options = harness.app.clone().oneshot(req_options).await.unwrap();
    assert_eq!(res_options.status(), StatusCode::OK);
    assert_eq!(
        res_options.headers().get("access-control-allow-origin").unwrap(),
        "*"
    );
    harness.teardown().await;
}

#[tokio::test]
async fn test_get_preview_vtt_storyboard() {
    let harness = setup_preview_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri(format!("/preview-vtt/{}", harness.test_filename))
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "text/vtt; charset=utf-8"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let text = String::from_utf8(bytes.to_vec()).unwrap();

    assert!(text.starts_with("WEBVTT\n"));
    assert!(text.contains(&format!(
        "/seek-preview/{}/thumb_00000.jpg",
        harness.test_filename
    )));
    assert!(text.contains("00:00:00.000 --> 00:00:05.000"));
    harness.teardown().await;
}

#[tokio::test]
async fn test_invalid_thumbnail_name_404() {
    let harness = setup_preview_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri(format!(
            "/seek-preview/{}/invalid_name.png",
            harness.test_filename
        ))
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    harness.teardown().await;
}

#[tokio::test]
async fn test_preview_traversal_denied() {
    let harness = setup_preview_test().await;

    let req = Request::builder()
        .method(Method::GET)
        .uri("/seek-preview/..%2Fsecret.mp4/thumb_00000.jpg")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert!(
        res.status() == StatusCode::FORBIDDEN
            || res.status() == StatusCode::NOT_FOUND
            || res.status() == StatusCode::BAD_REQUEST
    );
    harness.teardown().await;
}
