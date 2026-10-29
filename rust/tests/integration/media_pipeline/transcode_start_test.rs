use axum::{
    body::Body,
    http::{Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app_full, db, services::system_service::SystemService};
use sqlx::PgPool;
use std::fs;
use std::path::PathBuf;
use tower::ServiceExt;

use std::sync::atomic::{AtomicUsize, Ordering};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

async fn setup_test_app_with_temp_media() -> (PgPool, axum::Router, PathBuf) {
    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_test_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");

    // Use a clean temporary media root for deterministic isolation
    let count = COUNTER.fetch_add(1, Ordering::SeqCst);
    let raw_temp = std::env::temp_dir().join(format!(
        "rust_test_transcode_start_{}_{}",
        std::process::id(),
        count
    ));
    let _ = fs::create_dir_all(&raw_temp);
    let temp_dir = raw_temp.canonicalize().unwrap_or(raw_temp);

    // Clean any stray test jobs only on initial setup to avoid concurrent test deletion races
    if count == 0 {
        let _ = sqlx::query("DELETE FROM transcode_jobs WHERE filename LIKE '%rust_test_job_%' OR filename LIKE '%test_sample_%'")
            .execute(&pool)
            .await;
    }

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
    let _ = sqlx::query("DELETE FROM transcode_jobs WHERE filename = $1")
        .bind(&sample_name)
        .execute(&pool)
        .await;

    let _ = fs::remove_file(&sample_path);
    let _ = fs::remove_dir_all(&temp_dir);
}

#[tokio::test]
async fn test_transcode_start_quality_specific_enqueues_quality_job() {
    let (pool, app, temp_dir) = setup_test_app_with_temp_media().await;

    let sample_name = format!("rust_test_job_start_q_{}.mkv", std::process::id());
    let sample_path = temp_dir.join(&sample_name);
    fs::write(
        &sample_path,
        b"dummy mkv bytes for quality transcode start test",
    )
    .unwrap();

    let _ = sqlx::query("DELETE FROM transcode_jobs WHERE filename = $1")
        .bind(&sample_name)
        .execute(&pool)
        .await;

    // 1. POST /api/transcode/start/{sample_name}?quality=720p
    let req = Request::builder()
        .method(Method::POST)
        .uri(format!("/api/transcode/start/{}?quality=720p", sample_name))
        .header("content-type", "application/json")
        .body(Body::empty())
        .unwrap();

    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["status"], "queued");
    assert_eq!(json["quality"], "720p");

    // Verify row in database has mode "hls:720p" and priority 10 (interactive)
    let row: (String, String, i32) =
        sqlx::query_as("SELECT mode, status, priority FROM transcode_jobs WHERE filename = $1")
            .bind(&sample_name)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(row.0, "hls:720p");
    assert_eq!(row.1, "queued");
    assert_eq!(row.2, 10);

    // 2. GET /api/transcode-status/{sample_name}?quality=720p returns queued
    let req_status = Request::builder()
        .method(Method::GET)
        .uri(format!(
            "/api/transcode-status/{}?quality=720p",
            sample_name
        ))
        .body(Body::empty())
        .unwrap();
    let res_status = app.clone().oneshot(req_status).await.unwrap();
    assert_eq!(res_status.status(), StatusCode::OK);
    let bytes_status = res_status.into_body().collect().await.unwrap().to_bytes();
    let json_status: serde_json::Value = serde_json::from_slice(&bytes_status).unwrap();
    assert_eq!(json_status["status"], "queued");
    assert_eq!(json_status["is_complete"], false);

    // Clean up
    let _ = sqlx::query("DELETE FROM transcode_jobs WHERE filename = $1")
        .bind(&sample_name)
        .execute(&pool)
        .await;
    let _ = fs::remove_file(&sample_path);
    let _ = fs::remove_dir_all(&temp_dir);
}

#[tokio::test]
async fn test_transcode_start_and_status_when_quality_already_complete() {
    let (pool, _app, temp_dir) = setup_test_app_with_temp_media().await;
    let config = media_server_api::test_support::test_config().await;

    let count = COUNTER.fetch_add(1, Ordering::SeqCst);
    let temp_cache =
        std::env::temp_dir().join(format!("rust_test_cache_{}_{}", std::process::id(), count));
    let _ = fs::create_dir_all(&temp_cache);

    let mut media_roots = config.media_roots.clone();
    media_roots.insert(0, temp_dir.clone());
    let system_service = SystemService::new();
    let app = create_app_full(
        pool.clone(),
        system_service,
        media_roots.clone(),
        temp_cache.clone(),
        None,
        Some(config.flask_origin),
    );

    let sample_name = format!("rust_test_job_complete_{}.mkv", std::process::id());
    let sample_path = temp_dir.join(&sample_name);
    fs::write(&sample_path, b"dummy video bytes").unwrap();

    // Create 720p completed cache folder for this video
    use media_server_api::services::hls_service::HlsService;
    let base_hls_dir = HlsService::find_hls_dir(&sample_path, &media_roots, &temp_cache);
    let q_dir = base_hls_dir.join("720p");
    let _ = fs::create_dir_all(&q_dir);
    let pl_content = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.000,\nsegment_000000.m4s\n#EXT-X-ENDLIST\n";
    fs::write(q_dir.join("playlist.m3u8"), pl_content).unwrap();

    // 1. GET /api/transcode-status/{sample_name}?quality=720p should report complete
    let req_status = Request::builder()
        .method(Method::GET)
        .uri(format!(
            "/api/transcode-status/{}?quality=720p",
            sample_name
        ))
        .body(Body::empty())
        .unwrap();
    let res_status = app.clone().oneshot(req_status).await.unwrap();
    assert_eq!(res_status.status(), StatusCode::OK);
    let bytes_status = res_status.into_body().collect().await.unwrap().to_bytes();
    let json_status: serde_json::Value = serde_json::from_slice(&bytes_status).unwrap();
    assert_eq!(json_status["status"], "complete");
    assert_eq!(json_status["is_complete"], true);
    assert_eq!(json_status["progress"], 100.0);

    // 2. POST /api/transcode/start/{sample_name}?quality=720p should return ready
    let req_start = Request::builder()
        .method(Method::POST)
        .uri(format!("/api/transcode/start/{}?quality=720p", sample_name))
        .header("content-type", "application/json")
        .body(Body::empty())
        .unwrap();
    let res_start = app.clone().oneshot(req_start).await.unwrap();
    assert_eq!(res_start.status(), StatusCode::OK);
    let bytes_start = res_start.into_body().collect().await.unwrap().to_bytes();
    let json_start: serde_json::Value = serde_json::from_slice(&bytes_start).unwrap();
    assert_eq!(json_start["status"], "ready");

    // Clean up
    let _ = fs::remove_file(&sample_path);
    let _ = fs::remove_dir_all(&temp_dir);
    let _ = fs::remove_dir_all(&temp_cache);
}
