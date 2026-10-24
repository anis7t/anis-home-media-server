use axum::{
    body::Body,
    http::{header, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    create_app_full, db, routes::upload::{build_upload_routes, UploadState},
    services::system_service::SystemService, test_support,
};
use serde_json::{json, Value};
use sqlx::PgPool;
use std::sync::Arc;
use tower::ServiceExt;

const ADMIN_EMAIL: &str = "anis7t@gmail.com";
const VIEWER_EMAIL: &str = "viewer@example.com";
const ADMIN_SUB: &str = "sub_admin_anis";
const VIEWER_SUB: &str = "sub_viewer_test";

async fn setup_pool() -> PgPool {
    dotenvy::dotenv().ok();
    let config = test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test db");

    // Clean slate for the rows this suite owns.
    let _ = sqlx::query("DELETE FROM sessions WHERE id LIKE 'sess_admin_bootstrap_%' OR id LIKE 'sess_viewer_bootstrap_%'")
        .execute(&pool)
        .await;
    let _ = sqlx::query("DELETE FROM users WHERE google_sub IN ($1, $2)")
        .bind(ADMIN_SUB)
        .bind(VIEWER_SUB)
        .execute(&pool)
        .await;

    pool
}

async fn make_user_and_session(pool: &PgPool, sub: &str, email: &str, role: &str, sess_id: &str) {
    sqlx::query(
        r#"
        INSERT INTO users (google_sub, email, name, role, created_at, last_login_at)
        VALUES ($1, $2, 'Test', $3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (google_sub) DO UPDATE SET role = $3, email = $2
        "#,
    )
    .bind(sub)
    .bind(email)
    .bind(role)
    .execute(pool)
    .await
    .expect("upsert user");

    let user_id: i64 = sqlx::query_scalar("SELECT id FROM users WHERE google_sub = $1")
        .bind(sub)
        .fetch_one(pool)
        .await
        .expect("fetch user id");

    sqlx::query(
        r#"
        INSERT INTO sessions (id, user_id, email, role, expires_at)
        VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP + INTERVAL '30 days')
        ON CONFLICT (id) DO NOTHING
        "#,
    )
    .bind(sess_id)
    .bind(user_id)
    .bind(email)
    .bind(role)
    .execute(pool)
    .await
    .expect("insert session");
}

async fn teardown(pool: &PgPool) {
    let _ = sqlx::query("DELETE FROM sessions WHERE id LIKE 'sess_admin_bootstrap_%' OR id LIKE 'sess_viewer_bootstrap_%'")
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM users WHERE google_sub IN ($1, $2)")
        .bind(ADMIN_SUB)
        .bind(VIEWER_SUB)
        .execute(pool)
        .await;
}

#[tokio::test]
async fn role_for_email_reflects_admin_list() {
    // Temporarily set the env var; restore afterwards.
    let prev = std::env::var("MEDIA_SERVER_ADMIN_EMAILS").ok();
    std::env::set_var("MEDIA_SERVER_ADMIN_EMAILS", ADMIN_EMAIL);

    assert_eq!(
        media_server_api::services::auth_service::AuthService::role_for_email(ADMIN_EMAIL),
        "admin"
    );
    assert_eq!(
        media_server_api::services::auth_service::AuthService::role_for_email("someone@example.com"),
        "viewer"
    );
    // Case-insensitive + trimmed.
    assert_eq!(
        media_server_api::services::auth_service::AuthService::role_for_email("  ANIS7T@GMAIL.COM  "),
        "admin"
    );

    match prev {
        Some(v) => std::env::set_var("MEDIA_SERVER_ADMIN_EMAILS", v),
        None => std::env::remove_var("MEDIA_SERVER_ADMIN_EMAILS"),
    }
}

#[tokio::test]
async fn session_role_is_rechecked_per_request() {
    let pool = setup_pool().await;
    let sess_id = "sess_admin_bootstrap_1";
    make_user_and_session(&pool, ADMIN_SUB, ADMIN_EMAIL, "viewer", sess_id).await;

    // Build the full app so /api/auth/me is reachable.
    dotenvy::dotenv().ok();
    let temp_dir = std::env::temp_dir().join(format!("ms_admin_bt_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&temp_dir);
    std::fs::create_dir_all(&temp_dir).unwrap();
    let media_dir = temp_dir.join("media");
    let cache_dir = temp_dir.join("cache");
    std::fs::create_dir_all(&media_dir).unwrap();
    std::fs::create_dir_all(&cache_dir).unwrap();
    let system_service = SystemService::new();
    let app = create_app_full(
        pool.clone(),
        system_service,
        vec![media_dir.clone()],
        cache_dir.clone(),
        None,
        None,
    );

    // First request: role is 'viewer' (as stored at sign-in).
    let req = Request::builder()
        .uri("/api/auth/me")
        .header(header::COOKIE, format!("session_token={}", sess_id))
        .body(Body::empty())
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let v: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["role"].as_str(), Some("viewer"));
    assert_eq!(v["is_admin"].as_bool(), Some(false));

    // Promote in the DB without re-signing-in.
    sqlx::query("UPDATE users SET role = 'admin' WHERE google_sub = $1")
        .bind(ADMIN_SUB)
        .execute(&pool)
        .await
        .expect("promote");

    // Second request must reflect the new role (per-request re-check).
    let req = Request::builder()
        .uri("/api/auth/me")
        .header(header::COOKIE, format!("session_token={}", sess_id))
        .body(Body::empty())
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let v: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["role"].as_str(), Some("admin"));
    assert_eq!(v["is_admin"].as_bool(), Some(true));

    let _ = std::fs::remove_dir_all(&temp_dir);
    teardown(&pool).await;
}

#[tokio::test]
async fn upload_init_requires_admin_session() {
    // Reuse the upload test harness shape.
    dotenvy::dotenv().ok();
    let config = test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test db");

    // Set an admin PIN so the PIN channel is available but we test the session channel.
    sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '97531') ON CONFLICT (key) DO UPDATE SET value = '97531'",
    )
    .execute(&pool)
    .await
    .unwrap();

    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("ms_upload_admin_{}_{}", std::process::id(), nonce));
    let target = root.join("media");
    let tmp = root.join("tmp");
    std::fs::create_dir_all(&target).unwrap();
    std::fs::create_dir_all(&tmp).unwrap();

    // Two users: one admin, one viewer.
    for (sub, email, role) in [(ADMIN_SUB, ADMIN_EMAIL, "admin"), (VIEWER_SUB, VIEWER_EMAIL, "viewer")] {
        sqlx::query(
            r#"
            INSERT INTO users (google_sub, email, name, role, created_at, last_login_at)
            VALUES ($1, $2, 'Test', $3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            ON CONFLICT (google_sub) DO UPDATE SET role = $3, email = $2
            "#,
        )
        .bind(sub)
        .bind(email)
        .bind(role)
        .execute(&pool)
        .await
        .unwrap();
    }
    let admin_uid: i64 = sqlx::query_scalar("SELECT id FROM users WHERE google_sub = $1")
        .bind(ADMIN_SUB)
        .fetch_one(&pool)
        .await
        .unwrap();
    let viewer_uid: i64 = sqlx::query_scalar("SELECT id FROM users WHERE google_sub = $1")
        .bind(VIEWER_SUB)
        .fetch_one(&pool)
        .await
        .unwrap();

    let admin_sess = "sess_admin_bootstrap_upl";
    let viewer_sess = "sess_viewer_bootstrap_upl";
    for (sid, uid, email, role) in [
        (admin_sess, admin_uid, ADMIN_EMAIL, "admin"),
        (viewer_sess, viewer_uid, VIEWER_EMAIL, "viewer"),
    ] {
        sqlx::query(
            r#"
            INSERT INTO sessions (id, user_id, email, role, expires_at)
            VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP + INTERVAL '30 days')
            ON CONFLICT (id) DO NOTHING
            "#,
        )
        .bind(sid)
        .bind(uid)
        .bind(email)
        .bind(role)
        .execute(&pool)
        .await
        .unwrap();
    }

    let scan_trigger: Arc<dyn Fn() -> bool + Send + Sync> = Arc::new(|| false);
    let app = build_upload_routes(UploadState {
        pool: Arc::new(pool.clone()),
        media_root: target.clone(),
        upload_tmp: tmp.clone(),
        upload_target_dir: target.clone(),
        scan_trigger,
    });

    let payload = json!({"filename": "auth.mp4", "size": 10});

    // Anonymous -> 403
    let anon = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/upload/chunk/init")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(anon.status(), StatusCode::FORBIDDEN);

    // Viewer session -> 403
    let viewer = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/upload/chunk/init")
                .header(header::CONTENT_TYPE, "application/json")
                .header(header::COOKIE, format!("session_token={}", viewer_sess))
                .body(Body::from(payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(viewer.status(), StatusCode::FORBIDDEN);

    // Admin session -> past the admin gate (validation may reject the payload, but not 403).
    let admin = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/upload/chunk/init")
                .header(header::CONTENT_TYPE, "application/json")
                .header(header::COOKIE, format!("session_token={}", admin_sess))
                .body(Body::from(payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_ne!(admin.status(), StatusCode::FORBIDDEN);

    // Cleanup
    let _ = sqlx::query("DELETE FROM sessions WHERE id IN ($1, $2)")
        .bind(admin_sess)
        .bind(viewer_sess)
        .execute(&pool)
        .await;
    let _ = sqlx::query("DELETE FROM users WHERE google_sub IN ($1, $2)")
        .bind(ADMIN_SUB)
        .bind(VIEWER_SUB)
        .execute(&pool)
        .await;
    let _ = sqlx::query("DELETE FROM settings WHERE key = 'admin_pin'")
        .execute(&pool)
        .await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn config_admin_emails_empty_by_default() {
    // When unset, no one is promoted by email.
    let prev = std::env::var("MEDIA_SERVER_ADMIN_EMAILS").ok();
    std::env::remove_var("MEDIA_SERVER_ADMIN_EMAILS");
    assert!(media_server_api::config::admin_emails().is_empty());
    assert_eq!(
        media_server_api::services::auth_service::AuthService::role_for_email("anis7t@gmail.com"),
        "viewer"
    );
    if let Some(v) = prev {
        std::env::set_var("MEDIA_SERVER_ADMIN_EMAILS", v);
    }
}