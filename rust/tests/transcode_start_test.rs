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
use std::fs;
use std::path::PathBuf;
use tower::ServiceExt;

use std::sync::atomic::{AtomicUsize, Ordering};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

async fn setup_test_app_with_temp_media() -> (PgPool, axum::Router, PathBuf) {
    let config = AppConfig::from_env();
    let pool = db::create_test_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");

    // Use a clean temporary media root for deterministic isolation
    let count = COUNTER.fetch_add(1, Ordering::SeqCst);
    let raw_temp = std::env::temp_dir().join(format!("rust_test_transcode_start_{}_{}", std::process::id(), count));
    let _ = fs::create_dir_all(&raw_temp);
    let temp_dir = raw_temp.canonicalize().unwrap_or(raw_temp);

    // Clean any stray test jobs
    let _ = sqlx::query("DELETE FROM transcode_jobs WHERE filename LIKE '%rust_test_job_%' OR filename LIKE '%test_sample_%'")
        .execute(&pool)
        .await;

    let mut media_roots = config.media_roots.clone();
    media_roots.insert(0, temp_dir.clone());

    let system_service = SystemService::new();
    let app = create_app_full(
        pool.clone(),
        system_service,
        media_roots,
        config.cache_dir,
        None,
        Some(config.flask_origin),
    );

    (pool, app, temp_dir)
}

#[tokio::test]
async fn test_transcode_start_nonexistent_file_returns_404() {
    let (_pool, app, temp_dir) = setup_test_app_with_temp_media().await;

    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/transcode/start/rust_probe_nonexistent_title.mkv")
        .header("content-type", "application/json")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[tokio::test]
async fn test_transcode_start_direct_playable_returns_ready() {
    let (_pool, app, temp_dir) = setup_test_app_with_temp_media().await;

    // Create a dummy mp4 file
    let sample_name = format!("rust_test_job_direct_{}.mp4", std::process::id());
    let sample_path = temp_dir.join(&sample_name);
    fs::write(&sample_path, b"dummy mp4 bytes for transcode start test").unwrap();

    let req = Request::builder()
        .method(Method::POST)
        .uri(format!("/api/transcode/start/{}", sample_name))
        .header("content-type", "application/json")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["status"], "ready");

    let _ = fs::remove_file(&sample_path);
    let _ = fs::remove_dir_all(&temp_dir);
}

#[tokio::test]
async fn test_transcode_start_mkv_enqueues_job() {
    let (pool, app, temp_dir) = setup_test_app_with_temp_media().await;

    // Create a dummy mkv file namespaced per AGENTS.md §9
    let sample_name = format!("rust_test_job_start_{}.mkv", std::process::id());
    let sample_path = temp_dir.join(&sample_name);
    fs::write(&sample_path, b"dummy mkv bytes for transcode start test").unwrap();

    // Clean any pre-existing job row
    sqlx::query("DELETE FROM transcode_jobs WHERE filename = $1")
        .bind(&sample_name)
        .execute(&pool)
        .await
        .unwrap();

    let req = Request::builder()
        .method(Method::POST)
        .uri(format!("/api/transcode/start/{}", sample_name))
        .header("content-type", "application/json")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["status"], "queued");

    // Clean up job row and temp file immediately
    let _ = sqlx::query("DELETE FROM transcode_jobs WHERE filename = $1 OR filename LIKE '%rust_test_job_%'")
        .bind(&sample_name)
        .execute(&pool)
        .await;

    let _ = fs::remove_file(&sample_path);
    let _ = fs::remove_dir_all(&temp_dir);
}
