use axum::{
    body::Body,
    extract::Request,
    http::{header, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    create_app_full, db, services::system_service::SystemService,
};
use serde_json::{json, Value};
use sqlx::{PgPool, Row};
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

        let temp_dir = std::env::temp_dir().join(format!("ms_qr_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::create_dir_all(&temp_dir);

        let media_dir = temp_dir.join("media");
        let cache_dir = temp_dir.join("cache");
        fs::create_dir_all(&media_dir).unwrap();
        fs::create_dir_all(&cache_dir).unwrap();

        let system_service = SystemService::new();
        let app = create_app_full(
            pool.clone(),
            system_service,
            vec![media_dir],
            cache_dir,
            None,
            None,
        );

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

fn extract_cookie(headers: &axum::http::HeaderMap, name: &str) -> Option<String> {
    for val in headers.get_all(header::SET_COOKIE) {
        if let Ok(s) = val.to_str() {
            if let Some(cookie) = s.split(';').next() {
                if let Some((k, v)) = cookie.split_once('=') {
                    if k.trim() == name {
                        return Some(v.trim().to_string());
                    }
                }
            }
        }
    }
    None
}

async fn create_authenticated_user(pool: &PgPool, sub: &str) -> (i64, String) {
    let row = sqlx::query(
        r#"
        INSERT INTO users (google_sub, email, name, role, created_at, last_login_at)
        VALUES ($1, $2, 'Test Mobile User', 'user', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (google_sub) DO UPDATE SET last_login_at = CURRENT_TIMESTAMP
        RETURNING id
        "#,
    )
    .bind(sub)
    .bind(format!("{}@test.local", sub))
    .fetch_one(pool)
    .await
    .unwrap();

    let user_id: i64 = row.get("id");
    let session_id = format!("sess_phone_{}", sub);

    sqlx::query(
        r#"
        INSERT INTO sessions (id, user_id, email, role, expires_at)
        VALUES ($1, $2, $3, 'user', CURRENT_TIMESTAMP + INTERVAL '1 hour')
        ON CONFLICT (id) DO UPDATE SET expires_at = CURRENT_TIMESTAMP + INTERVAL '1 hour'
        "#,
    )
    .bind(&session_id)
    .bind(user_id)
    .bind(format!("{}@test.local", sub))
    .execute(pool)
    .await
    .unwrap();

    (user_id, session_id)
}

#[tokio::test]
async fn test_qr_happy_path_handshake() {
    let ctx = TestContext::new().await;
    let (_user_id, phone_session) = create_authenticated_user(&ctx.pool, "qr_user_happy").await;

    // 1. TV creates pair session
    let req = Request::builder()
        .method("POST")
        .uri("/api/auth/qr")
        .header("x-forwarded-for", "10.10.1.1")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let secret_cookie = extract_cookie(resp.headers(), "ms_qr_secret")
        .expect("Create must set ms_qr_secret cookie");

    let body_bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body_bytes).unwrap();
    let qr_id = body["qr_id"].as_str().unwrap().to_string();
    let code = body["code"].as_str().unwrap().to_string();
    let sig = body["sig"].as_str().unwrap().to_string();

    assert!(!qr_id.is_empty());
    assert_eq!(code.len(), 5);

    // 2. TV polls status: should be "pending"
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/status", qr_id))
        .header("x-forwarded-for", "10.10.1.1")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body_bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body_bytes).unwrap();
    assert_eq!(body["status"], "pending");

    // 3. Phone looks up code
    let req = Request::builder()
        .method("POST")
        .uri("/api/auth/qr/lookup")
        .header("x-forwarded-for", "10.10.1.2")
        .header(header::COOKIE, format!("session_token={}", phone_session))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "code": code }).to_string()))
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body_bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body_bytes).unwrap();
    assert_eq!(body["qr_id"], qr_id);

    // 4. Phone confirms pairing
    let req = Request::builder()
        .method("POST")
        .uri(format!("/api/auth/qr/{}/confirm", qr_id))
        .header("x-forwarded-for", "10.10.1.2")
        .header(header::COOKIE, format!("session_token={}", phone_session))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({
                "code": code,
                "sig": sig,
                "device_name": "Living Room OLED TV"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // 5. TV polls status: should now be "confirmed"
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/status", qr_id))
        .header("x-forwarded-for", "10.10.1.1")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body_bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body_bytes).unwrap();
    assert_eq!(body["status"], "confirmed");

    // 6. TV finalizes session
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header("x-forwarded-for", "10.10.1.1")
        .header(header::COOKIE, format!("ms_qr_secret={}", secret_cookie))
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::TEMPORARY_REDIRECT);

    let session_cookie = extract_cookie(resp.headers(), "session_token")
        .expect("Finalize must issue session_token cookie");
    assert!(session_cookie.starts_with("sess_"));
}

#[tokio::test]
async fn test_qr_boundary_expiry_grace_extension() {
    let ctx = TestContext::new().await;
    let (_user_id, phone_session) = create_authenticated_user(&ctx.pool, "qr_user_grace").await;

    // 1. Create pair session
    let req = Request::builder()
        .method("POST")
        .uri("/api/auth/qr")
        .header("x-forwarded-for", "10.10.2.1")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    let secret_cookie = extract_cookie(resp.headers(), "ms_qr_secret").unwrap();
    let body_bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body_bytes).unwrap();
    let qr_id = body["qr_id"].as_str().unwrap().to_string();
    let code = body["code"].as_str().unwrap().to_string();

    // 2. Simulate session arriving right at the 2-minute deadline (T - 1s)
    sqlx::query("UPDATE device_pair_sessions SET expires_at = CURRENT_TIMESTAMP + INTERVAL '1 second' WHERE id = $1")
        .bind(&qr_id)
        .execute(&ctx.pool)
        .await
        .unwrap();

    // 3. Phone confirms right at boundary
    let req = Request::builder()
        .method("POST")
        .uri(format!("/api/auth/qr/{}/confirm", qr_id))
        .header("x-forwarded-for", "10.10.2.2")
        .header(header::COOKIE, format!("session_token={}", phone_session))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({
                "code": code,
                "device_name": "Boundary Bedroom TV"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // 4. Verify in DB that expires_at was extended by the 60s grace window
    let row = sqlx::query("SELECT expires_at > CURRENT_TIMESTAMP + INTERVAL '45 seconds' AS has_grace FROM device_pair_sessions WHERE id = $1")
        .bind(&qr_id)
        .fetch_one(&ctx.pool)
        .await
        .unwrap();
    let has_grace: bool = row.get("has_grace");
    assert!(has_grace, "expires_at must be extended by at least 60s grace window upon confirmation");

    // 5. TV finalizes cleanly without 400 Bad Request
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header("x-forwarded-for", "10.10.2.1")
        .header(header::COOKIE, format!("ms_qr_secret={}", secret_cookie))
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::TEMPORARY_REDIRECT);
    let session_cookie = extract_cookie(resp.headers(), "session_token");
    assert!(session_cookie.is_some());
}

#[tokio::test]
async fn test_qr_finalize_idempotency_window() {
    let ctx = TestContext::new().await;
    let (_user_id, phone_session) = create_authenticated_user(&ctx.pool, "qr_user_idempotent").await;

    // 1. Create & Confirm
    let req = Request::builder()
        .method("POST")
        .uri("/api/auth/qr")
        .header("x-forwarded-for", "10.10.3.1")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    let secret_cookie = extract_cookie(resp.headers(), "ms_qr_secret").unwrap();
    let body_bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body_bytes).unwrap();
    let qr_id = body["qr_id"].as_str().unwrap().to_string();
    let code = body["code"].as_str().unwrap().to_string();

    let req = Request::builder()
        .method("POST")
        .uri(format!("/api/auth/qr/{}/confirm", qr_id))
        .header("x-forwarded-for", "10.10.3.2")
        .header(header::COOKIE, format!("session_token={}", phone_session))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "code": code, "device_name": "Idempotent TV" }).to_string()))
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // 2. First finalize hit: returns session cookie
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header("x-forwarded-for", "10.10.3.1")
        .header(header::COOKIE, format!("ms_qr_secret={}", secret_cookie))
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::TEMPORARY_REDIRECT);
    let first_sess = extract_cookie(resp.headers(), "session_token").unwrap();

    // 3. Second finalize hit immediately (within 10-second idempotency window): returns SAME session cookie
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header("x-forwarded-for", "10.10.3.1")
        .header(header::COOKIE, format!("ms_qr_secret={}", secret_cookie))
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::TEMPORARY_REDIRECT);
    let second_sess = extract_cookie(resp.headers(), "session_token").unwrap();
    assert_eq!(first_sess, second_sess);

    // 4. Simulate passage of >10 seconds since finalization
    sqlx::query("UPDATE device_pair_sessions SET finalized_at = CURRENT_TIMESTAMP - INTERVAL '15 seconds' WHERE id = $1")
        .bind(&qr_id)
        .execute(&ctx.pool)
        .await
        .unwrap();

    // 5. Third finalize hit: must fail with 400 Bad Request
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header("x-forwarded-for", "10.10.3.1")
        .header(header::COOKIE, format!("ms_qr_secret={}", secret_cookie))
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_qr_finalize_security_guards() {
    let ctx = TestContext::new().await;
    let (_user_id, phone_session) = create_authenticated_user(&ctx.pool, "qr_user_sec").await;

    // Create & Confirm
    let req = Request::builder()
        .method("POST")
        .uri("/api/auth/qr")
        .header("x-forwarded-for", "10.10.4.1")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    let body_bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body_bytes).unwrap();
    let qr_id = body["qr_id"].as_str().unwrap().to_string();
    let code = body["code"].as_str().unwrap().to_string();

    let req = Request::builder()
        .method("POST")
        .uri(format!("/api/auth/qr/{}/confirm", qr_id))
        .header("x-forwarded-for", "10.10.4.2")
        .header(header::COOKIE, format!("session_token={}", phone_session))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "code": code, "device_name": "Sec TV" }).to_string()))
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Attempt finalize without secret cookie -> 403 Forbidden
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header("x-forwarded-for", "10.10.4.1")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // Attempt finalize with invalid secret cookie -> 403 Forbidden
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header("x-forwarded-for", "10.10.4.1")
        .header(header::COOKIE, "ms_qr_secret=completely_wrong_secret")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn test_qr_finalize_unconfirmed_fails() {
    let ctx = TestContext::new().await;

    // Create session (unconfirmed)
    let req = Request::builder()
        .method("POST")
        .uri("/api/auth/qr")
        .header("x-forwarded-for", "10.10.5.1")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    let secret_cookie = extract_cookie(resp.headers(), "ms_qr_secret").unwrap();
    let body_bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body_bytes).unwrap();
    let qr_id = body["qr_id"].as_str().unwrap().to_string();

    // Attempt finalize before confirmation -> 400 Bad Request
    let req = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header("x-forwarded-for", "10.10.5.1")
        .header(header::COOKIE, format!("ms_qr_secret={}", secret_cookie))
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}
