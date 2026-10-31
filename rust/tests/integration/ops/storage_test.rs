use axum::{
    body::Body,
    http::{header, Request, StatusCode},
    Router,
};
use http_body_util::BodyExt;
use media_server_api::{create_app_full, db, services::system_service::SystemService};
use serde_json::json;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use tower::ServiceExt;

static TEST_COUNTER: AtomicUsize = AtomicUsize::new(1);

struct StorageTestContext {
    app: Router,
    temp_dir: PathBuf,
    media_dir: PathBuf,
    cache_dir: PathBuf,
    archive_dir: PathBuf,
    pool: sqlx::PgPool,
    admin_session: String,
}

impl StorageTestContext {
    async fn setup() -> Self {
        let config = media_server_api::test_support::test_config().await;
        let pool = db::create_pool(&config.database_url)
            .await
            .expect("Failed to connect to test database");

        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        let temp_dir =
            std::env::temp_dir().join(format!("rust_storage_test_{}_{}", std::process::id(), id));
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::create_dir_all(&temp_dir);

        let base = &temp_dir;
        let media_dir = base.join("media");
        let cache_dir = base.join("cache");
        let archive_dir = media_dir.join(".archive");

        fs::create_dir_all(&media_dir).unwrap();
        fs::create_dir_all(&cache_dir).unwrap();
        fs::create_dir_all(cache_dir.join("hls")).unwrap();
        fs::create_dir_all(cache_dir.join("previews")).unwrap();
        fs::create_dir_all(&archive_dir).unwrap();
        std::env::set_var("MEDIA_SERVER_ARCHIVE_DIR", &archive_dir);

        let admin_sub = format!("sub_storage_admin_{}_{}", std::process::id(), id);
        let admin_session = format!("sess_storage_admin_{}_{}", std::process::id(), id);

        sqlx::query(
            "INSERT INTO users (google_sub, email, name, role, created_at, last_login_at) \
             VALUES ($1, $2, 'Storage Admin', 'admin', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) \
             ON CONFLICT (google_sub) DO UPDATE SET email = EXCLUDED.email, role = EXCLUDED.role",
        )
        .bind(&admin_sub)
        .bind("admin.storage@example.com")
        .execute(&pool)
        .await
        .unwrap();

        let admin_user_id: i64 = sqlx::query_scalar("SELECT id FROM users WHERE google_sub = $1")
            .bind(&admin_sub)
            .fetch_one(&pool)
            .await
            .unwrap();

        sqlx::query(
            "INSERT INTO sessions (id, user_id, email, role, expires_at) \
             VALUES ($1, $2, $3, 'admin', CURRENT_TIMESTAMP + INTERVAL '30 days') \
             ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id, \
                 email = EXCLUDED.email, role = EXCLUDED.role, expires_at = EXCLUDED.expires_at",
        )
        .bind(&admin_session)
        .bind(admin_user_id)
        .bind("admin.storage@example.com")
        .execute(&pool)
        .await
        .unwrap();

        // Reset retention policy to keep
        sqlx::query(
            "INSERT INTO settings (key, value) VALUES ('retention_policy', 'keep') ON CONFLICT (key) DO UPDATE SET value = 'keep'"
        )
        .execute(&pool)
        .await
        .unwrap();

        let system_service = SystemService::new();
        let media_roots = vec![media_dir.clone(), archive_dir.clone()];

        let app = create_app_full(
            pool.clone(),
            system_service,
            media_roots,
            cache_dir.clone(),
            None,
            None,
        );

        Self {
            app,
            temp_dir,
            media_dir,
            cache_dir,
            archive_dir,
            pool,
            admin_session,
        }
    }
}

impl Drop for StorageTestContext {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.temp_dir);
    }
}

#[tokio::test]
async fn test_storage_settings_get_and_post() {
    let ctx = StorageTestContext::setup().await;

    // 1. GET /api/storage/settings is non-gated
    let req = Request::builder()
        .method("GET")
        .uri("/api/storage/settings")
        .body(Body::empty())
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(body["retention_policy"], "keep");
    assert!(body["allowed_policies"].is_array());
    assert!(body["archive_dir"].is_string());

    // 2. POST without session fails 403
    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/settings")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({ "retention_policy": "archive" }).to_string(),
        ))
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);

    // 3. POST with static PIN without session fails 403 (decommissioned)
    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/settings")
        .header(header::CONTENT_TYPE, "application/json")
        .header("X-Admin-Pin", "97531")
        .body(Body::from(
            json!({ "retention_policy": "archive" }).to_string(),
        ))
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);

    // 4. POST with admin session but invalid policy fails 400
    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/settings")
        .header(header::CONTENT_TYPE, "application/json")
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .body(Body::from(
            json!({ "retention_policy": "invalid_mode" }).to_string(),
        ))
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);

    // 5. POST with admin session cookie succeeds
    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/settings")
        .header(header::CONTENT_TYPE, "application/json")
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .body(Body::from(
            json!({ "retention_policy": "archive" }).to_string(),
        ))
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["success"], true);
    assert_eq!(body["retention_policy"], "archive");

    // 6. Verify GET now reflects "archive"
    let req = Request::builder()
        .method("GET")
        .uri("/api/storage/settings")
        .body(Body::empty())
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["retention_policy"], "archive");
}

#[tokio::test]
async fn test_storage_audit_and_purge() {
    let ctx = StorageTestContext::setup().await;

    // Ensure clean state without residual running jobs from prior tests
    let _ = sqlx::query("DELETE FROM transcode_jobs WHERE status IN ('queued', 'running')")
        .execute(&ctx.pool)
        .await;

    // Reset scanner busy flag so previous tests don't cause purge refusal
    media_server_api::services::scan_service::ScanService::set_busy_for_test(false);

    // Create an active video file
    let video_path = ctx.media_dir.join("TestMovie.mp4");
    fs::write(&video_path, b"dummy video content").unwrap();

    // Insert movie row into database
    sqlx::query(
        "INSERT INTO movies (filename, title, year) VALUES ('TestMovie.mp4', 'Test Movie', 2024) ON CONFLICT (filename) DO NOTHING"
    )
    .execute(&ctx.pool)
    .await
    .unwrap();

    // 1. Audit without session is 403
    let req = Request::builder()
        .method("GET")
        .uri("/api/storage/audit")
        .body(Body::empty())
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);

    // 2. Audit with admin session succeeds
    let req = Request::builder()
        .method("GET")
        .uri("/api/storage/audit")
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .body(Body::empty())
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

    assert!(body["storage"].is_object());
    assert!(body["audit"].is_object());
    assert_eq!(body["audit"]["degraded"], false);

    // 3. Purge orphans dry-run with admin session
    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/purge-orphans?dry_run=true")
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .body(Body::empty())
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(body["success"], true, "Purge refused with body: {:?}", body);
    assert_eq!(body["result"]["dry_run"], true);
    assert_eq!(body["result"]["refused"], false);

    // 4. Purge refusal when transcode job is active
    sqlx::query(
        "INSERT INTO transcode_jobs (filename, mode, status) VALUES ('ActiveJob.mp4', 'hls', 'running') ON CONFLICT (filename, mode) DO UPDATE SET status = 'running'"
    )
    .execute(&ctx.pool)
    .await
    .unwrap();

    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/purge-orphans")
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "dry_run": true }).to_string()))
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(body["success"], false);
    assert_eq!(body["result"]["refused"], true);
    assert!(body["result"]["reason"]
        .as_str()
        .unwrap()
        .contains("Transcode in progress"));

    // Cleanup active job and test movie
    sqlx::query("DELETE FROM transcode_jobs WHERE filename = 'ActiveJob.mp4'")
        .execute(&ctx.pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM movies WHERE filename = 'TestMovie.mp4'")
        .execute(&ctx.pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn test_storage_archive_endpoint() {
    let ctx = StorageTestContext::setup().await;

    // Create a video file
    let raw_video_path = ctx.media_dir.join("ArchiveMe.mkv");
    fs::write(&raw_video_path, b"archive me video content").unwrap();
    let video_path = raw_video_path.canonicalize().unwrap();

    // 1. Without session returns 403
    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/archive/ArchiveMe.mkv")
        .body(Body::empty())
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);

    // 2. Nonexistent file returns 404
    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/archive/DoesNotExist.mkv")
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .body(Body::empty())
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);

    // 3. Incomplete transcode returns 400
    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/archive/ArchiveMe.mkv")
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .body(Body::empty())
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["success"], false);
    assert_eq!(body["result"]["status"], "incomplete");

    // 4. Complete transcode: write playlist with #EXT-X-ENDLIST
    let hls_candidates = media_server_api::services::hls_service::HlsService::get_hls_candidates(
        &video_path,
        &[ctx.media_dir.clone(), ctx.archive_dir.clone()],
    );
    let primary_key = hls_candidates.into_iter().next().unwrap();
    let hls_job_dir = ctx.cache_dir.join("hls").join(primary_key);
    fs::create_dir_all(&hls_job_dir).unwrap();
    fs::write(
        hls_job_dir.join("playlist.m3u8"),
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:6.0,\nseg_000.ts\n#EXT-X-ENDLIST\n",
    )
    .unwrap();

    // Re-run archive request with admin session
    let req = Request::builder()
        .method("POST")
        .uri("/api/storage/archive/ArchiveMe.mkv")
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .body(Body::empty())
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(status, StatusCode::OK, "Body was: {:?}", body);

    assert_eq!(body["success"], true);
    assert_eq!(body["result"]["status"], "archived");

    // Verify source moved to archive directory
    assert!(!video_path.exists());
    let archived_target = ctx.archive_dir.join("ArchiveMe.mkv");
    assert!(archived_target.exists());
}
