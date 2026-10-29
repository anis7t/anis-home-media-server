use axum::{
    body::Body,
    extract::Request,
    http::{header, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app, db, services::system_service::SystemService};
use serde_json::{json, Value};
use sqlx::PgPool;
use std::fs;
use std::path::PathBuf;
use tower::ServiceExt;

struct TestContext {
    app: axum::Router,
    pool: PgPool,
    temp_dir: PathBuf,
}

impl TestContext {
    async fn new() -> Self {
        dotenvy::dotenv().ok();
        let config = media_server_api::test_support::test_config().await;
        let pool = db::create_pool(&config.database_url)
            .await
            .expect("Failed to connect to test db");

        let temp_dir =
            std::env::temp_dir().join(format!("ms_user_prog_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::create_dir_all(&temp_dir);

        let media_dir = temp_dir.join("media");
        let cache_dir = temp_dir.join("cache");
        fs::create_dir_all(&media_dir).unwrap();
        fs::create_dir_all(&cache_dir).unwrap();

        let system_service = SystemService::new();
        let app = create_app(pool.clone(), system_service, vec![media_dir], cache_dir);

        Self {
            app,
            pool,
            temp_dir,
        }
    }
}

impl Drop for TestContext {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.temp_dir);
    }
}

async fn create_test_user_and_session(
    pool: &PgPool,
    sub: &str,
    email: &str,
    session_id: &str,
) -> i64 {
    sqlx::query(
        r#"
        INSERT INTO users (google_sub, email, name, role, created_at, last_login_at)
        VALUES ($1, $2, 'Progress Test User', 'viewer', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (google_sub) DO UPDATE SET email = EXCLUDED.email
        "#,
    )
    .bind(sub)
    .bind(email)
    .execute(pool)
    .await
    .expect("upsert test user");

    let user_id: i64 = sqlx::query_scalar("SELECT id FROM users WHERE google_sub = $1")
        .bind(sub)
        .fetch_one(pool)
        .await
        .expect("fetch test user id");

    sqlx::query(
        r#"
        INSERT INTO sessions (id, user_id, email, role, expires_at)
        VALUES ($1, $2, $3, 'viewer', CURRENT_TIMESTAMP + INTERVAL '30 days')
        ON CONFLICT (id) DO UPDATE SET
            user_id = EXCLUDED.user_id,
            email = EXCLUDED.email,
            expires_at = EXCLUDED.expires_at
        "#,
    )
    .bind(session_id)
    .bind(user_id)
    .bind(email)
    .execute(pool)
    .await
    .expect("upsert test session");

    user_id
}

#[tokio::test]
async fn test_user_progress_isolation() {
    let ctx = TestContext::new().await;

    let user_a_id = create_test_user_and_session(
        &ctx.pool,
        "sub_prog_iso_a",
        "user_prog_a@test.com",
        "sess_prog_iso_a",
    )
    .await;

    let user_b_id = create_test_user_and_session(
        &ctx.pool,
        "sub_prog_iso_b",
        "user_prog_b@test.com",
        "sess_prog_iso_b",
    )
    .await;

    let filename = "movie_prog_isolation.mp4";

    // 1. User A posts progress (100s / 200s)
    let req_a = Request::builder()
        .method("POST")
        .uri("/api/progress")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::COOKIE, "session_token=sess_prog_iso_a")
        .body(Body::from(
            json!({
                "filename": filename,
                "position": 100.0,
                "duration": 200.0
            })
            .to_string(),
        ))
        .unwrap();

    let res_a = ctx.app.clone().oneshot(req_a).await.unwrap();
    assert_eq!(res_a.status(), StatusCode::OK);

    // 2. User B posts different progress on the SAME movie (50s / 200s)
    let req_b = Request::builder()
        .method("POST")
        .uri("/api/progress")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::COOKIE, "session_token=sess_prog_iso_b")
        .body(Body::from(
            json!({
                "filename": filename,
                "position": 50.0,
                "duration": 200.0
            })
            .to_string(),
        ))
        .unwrap();

    let res_b = ctx.app.clone().oneshot(req_b).await.unwrap();
    assert_eq!(res_b.status(), StatusCode::OK);

    // 3. User A queries progress -> receives 100.0
    let get_a = Request::builder()
        .method("GET")
        .uri(format!("/api/progress?filename={}", filename))
        .header(header::COOKIE, "session_token=sess_prog_iso_a")
        .body(Body::empty())
        .unwrap();

    let get_res_a = ctx.app.clone().oneshot(get_a).await.unwrap();
    assert_eq!(get_res_a.status(), StatusCode::OK);
    let bytes_a = get_res_a.into_body().collect().await.unwrap().to_bytes();
    let json_a: Value = serde_json::from_slice(&bytes_a).unwrap();
    assert_eq!(json_a["position"], 100.0);
    assert_eq!(json_a["duration"], 200.0);

    // 4. User B queries progress -> receives 50.0
    let get_b = Request::builder()
        .method("GET")
        .uri(format!("/api/progress?filename={}", filename))
        .header(header::COOKIE, "session_token=sess_prog_iso_b")
        .body(Body::empty())
        .unwrap();

    let get_res_b = ctx.app.clone().oneshot(get_b).await.unwrap();
    assert_eq!(get_res_b.status(), StatusCode::OK);
    let bytes_b = get_res_b.into_body().collect().await.unwrap().to_bytes();
    let json_b: Value = serde_json::from_slice(&bytes_b).unwrap();
    assert_eq!(json_b["position"], 50.0);
    assert_eq!(json_b["duration"], 200.0);

    // 5. Unauthenticated guest queries progress -> receives 0.0 (does not leak A or B)
    let get_guest = Request::builder()
        .method("GET")
        .uri(format!("/api/progress?filename={}", filename))
        .body(Body::empty())
        .unwrap();

    let get_res_guest = ctx.app.clone().oneshot(get_guest).await.unwrap();
    assert_eq!(get_res_guest.status(), StatusCode::OK);
    let bytes_guest = get_res_guest
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    let json_guest: Value = serde_json::from_slice(&bytes_guest).unwrap();
    assert_eq!(json_guest["position"], 0.0);

    // Cleanup
    let _ = sqlx::query("DELETE FROM users WHERE id = $1 OR id = $2")
        .bind(user_a_id)
        .bind(user_b_id)
        .execute(&ctx.pool)
        .await;
}

#[tokio::test]
async fn test_cross_device_progress_sync() {
    let ctx = TestContext::new().await;

    let user_id = create_test_user_and_session(
        &ctx.pool,
        "sub_prog_sync",
        "user_prog_sync@test.com",
        "sess_prog_sync",
    )
    .await;

    let dev_phone = "dev_sync_phone_001";
    let dev_tv = "dev_sync_tv_002";
    let filename = "movie_prog_sync.mp4";

    // Link both devices to this user in devices table
    sqlx::query(
        r#"
        INSERT INTO devices (device_id, device_name, device_type, user_id, first_seen, last_seen)
        VALUES ($1, 'Phone', 'Mobile', $3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
               ($2, 'Living Room TV', 'TV', $3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (device_id) DO UPDATE SET user_id = EXCLUDED.user_id
        "#,
    )
    .bind(dev_phone)
    .bind(dev_tv)
    .bind(user_id)
    .execute(&ctx.pool)
    .await
    .unwrap();

    // 1. Phone updates progress (position 350s / 1000s)
    let req_phone = Request::builder()
        .method("POST")
        .uri("/api/progress")
        .header(header::CONTENT_TYPE, "application/json")
        .header("x-device-id", dev_phone)
        .body(Body::from(
            json!({
                "filename": filename,
                "position": 350.0,
                "duration": 1000.0
            })
            .to_string(),
        ))
        .unwrap();

    let res_phone = ctx.app.clone().oneshot(req_phone).await.unwrap();
    assert_eq!(res_phone.status(), StatusCode::OK);

    // 2. TV (different device_id, but paired to same user) queries progress
    let req_tv = Request::builder()
        .method("GET")
        .uri(format!("/api/progress?filename={}", filename))
        .header("x-device-id", dev_tv)
        .body(Body::empty())
        .unwrap();

    let res_tv = ctx.app.clone().oneshot(req_tv).await.unwrap();
    assert_eq!(res_tv.status(), StatusCode::OK);
    let bytes_tv = res_tv.into_body().collect().await.unwrap().to_bytes();
    let json_tv: Value = serde_json::from_slice(&bytes_tv).unwrap();

    // Crucial assertion: TV receives Phone's updated position because both belong to user!
    assert_eq!(json_tv["position"], 350.0);
    assert_eq!(json_tv["duration"], 1000.0);

    // Cleanup
    let _ = sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user_id)
        .execute(&ctx.pool)
        .await;
}

#[tokio::test]
async fn test_guest_progress_isolation() {
    let ctx = TestContext::new().await;

    let user_id = create_test_user_and_session(
        &ctx.pool,
        "sub_prog_guest_iso",
        "user_prog_guest_iso@test.com",
        "sess_prog_guest_iso",
    )
    .await;

    let filename = "movie_prog_guest_test.mp4";

    // 1. Unauthenticated guest watches to 75.0s
    let req_guest = Request::builder()
        .method("POST")
        .uri("/api/progress")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({
                "filename": filename,
                "position": 75.0,
                "duration": 500.0
            })
            .to_string(),
        ))
        .unwrap();

    let res_guest = ctx.app.clone().oneshot(req_guest).await.unwrap();
    assert_eq!(res_guest.status(), StatusCode::OK);

    // 2. Guest queries -> receives 75.0
    let get_guest = Request::builder()
        .method("GET")
        .uri(format!("/api/progress?filename={}", filename))
        .body(Body::empty())
        .unwrap();

    let get_res_guest = ctx.app.clone().oneshot(get_guest).await.unwrap();
    assert_eq!(get_res_guest.status(), StatusCode::OK);
    let bytes_guest = get_res_guest
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    let json_guest: Value = serde_json::from_slice(&bytes_guest).unwrap();
    assert_eq!(json_guest["position"], 75.0);

    // 3. User with active session queries -> receives 0.0 (user has not watched it yet)
    let get_user = Request::builder()
        .method("GET")
        .uri(format!("/api/progress?filename={}", filename))
        .header(header::COOKIE, "session_token=sess_prog_guest_iso")
        .body(Body::empty())
        .unwrap();

    let get_res_user = ctx.app.clone().oneshot(get_user).await.unwrap();
    assert_eq!(get_res_user.status(), StatusCode::OK);
    let bytes_user = get_res_user.into_body().collect().await.unwrap().to_bytes();
    let json_user: Value = serde_json::from_slice(&bytes_user).unwrap();
    assert_eq!(json_user["position"], 0.0);

    // Cleanup
    let _ = sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user_id)
        .execute(&ctx.pool)
        .await;
    let _ = sqlx::query("DELETE FROM progress WHERE filename = $1")
        .bind(filename)
        .execute(&ctx.pool)
        .await;
}

#[tokio::test]
async fn test_cascading_user_delete_progress() {
    let ctx = TestContext::new().await;

    let user_id = create_test_user_and_session(
        &ctx.pool,
        "sub_prog_cascade",
        "user_prog_cascade@test.com",
        "sess_prog_cascade",
    )
    .await;

    let filename = "movie_prog_cascade.mp4";

    // 1. User records progress
    let req = Request::builder()
        .method("POST")
        .uri("/api/progress")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::COOKIE, "session_token=sess_prog_cascade")
        .body(Body::from(
            json!({
                "filename": filename,
                "position": 80.0,
                "duration": 400.0
            })
            .to_string(),
        ))
        .unwrap();

    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // 2. Assert progress row exists with user_id
    let count_before: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM progress WHERE user_id = $1 AND filename = $2")
            .bind(user_id)
            .bind(filename)
            .fetch_one(&ctx.pool)
            .await
            .unwrap();
    assert_eq!(count_before, 1);

    // 3. Delete user account
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user_id)
        .execute(&ctx.pool)
        .await
        .unwrap();

    // 4. Assert ON DELETE CASCADE removed the progress row
    let count_after: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM progress WHERE user_id = $1 AND filename = $2")
            .bind(user_id)
            .bind(filename)
            .fetch_one(&ctx.pool)
            .await
            .unwrap();
    assert_eq!(count_after, 0);
}
