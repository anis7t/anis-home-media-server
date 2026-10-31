use axum::{
    body::Body,
    http::{header, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    create_app_with_static, db, models::auth::*, services::system_service::SystemService,
};
use sqlx::PgPool;
use tower::ServiceExt;

const ADMIN_EMAIL: &str = "admin.otp.test@example.com";
const ADMIN_SUB: &str = "google_sub_admin_otp_test";

const VIEWER_EMAIL: &str = "viewer.otp.test@example.com";
const VIEWER_SUB: &str = "google_sub_viewer_otp_test";

const ADMIN_B_EMAIL: &str = "admin.b.otp.test@example.com";
const ADMIN_B_SUB: &str = "google_sub_admin_b_otp_test";

#[allow(dead_code)]
struct TestHarness {
    app: axum::Router,
    pool: PgPool,
    admin_user_id: i64,
    admin_session_token: String,
    viewer_user_id: i64,
    viewer_session_token: String,
    admin_b_user_id: i64,
    admin_b_session_token: String,
}

impl TestHarness {
    async fn setup() -> Self {
        dotenvy::dotenv().ok();
        // Configure test admin email allowlist
        std::env::set_var(
            "MEDIA_SERVER_ADMIN_EMAILS",
            format!("{},{}", ADMIN_EMAIL, ADMIN_B_EMAIL),
        );

        let config = media_server_api::test_support::test_config().await;
        let pool = db::create_pool(&config.database_url)
            .await
            .expect("Failed to connect to test db");

        // Cleanup prior test artifacts
        let _ = sqlx::query("DELETE FROM admin_access_otps")
            .execute(&pool)
            .await;
        let _ = sqlx::query("DELETE FROM sessions WHERE email IN ($1, $2, $3)")
            .bind(ADMIN_EMAIL)
            .bind(VIEWER_EMAIL)
            .bind(ADMIN_B_EMAIL)
            .execute(&pool)
            .await;
        let _ = sqlx::query("DELETE FROM users WHERE google_sub IN ($1, $2, $3)")
            .bind(ADMIN_SUB)
            .bind(VIEWER_SUB)
            .bind(ADMIN_B_SUB)
            .execute(&pool)
            .await;

        // 1. Seed Admin User A
        let admin_row = sqlx::query(
            r#"
            INSERT INTO users (google_sub, email, name, role)
            VALUES ($1, $2, 'Test Admin', 'admin')
            RETURNING id
            "#,
        )
        .bind(ADMIN_SUB)
        .bind(ADMIN_EMAIL)
        .fetch_one(&pool)
        .await
        .unwrap();
        let admin_user_id: i64 = sqlx::Row::get(&admin_row, "id");

        let admin_session_token = "sess_admin_otp_test_token_a".to_string();
        sqlx::query(
            r#"
            INSERT INTO sessions (id, user_id, email, role, expires_at)
            VALUES ($1, $2, $3, 'admin', CURRENT_TIMESTAMP + INTERVAL '1 day')
            "#,
        )
        .bind(&admin_session_token)
        .bind(admin_user_id)
        .bind(ADMIN_EMAIL)
        .execute(&pool)
        .await
        .unwrap();

        // 2. Seed Viewer User
        let viewer_row = sqlx::query(
            r#"
            INSERT INTO users (google_sub, email, name, role)
            VALUES ($1, $2, 'Test Viewer', 'viewer')
            RETURNING id
            "#,
        )
        .bind(VIEWER_SUB)
        .bind(VIEWER_EMAIL)
        .fetch_one(&pool)
        .await
        .unwrap();
        let viewer_user_id: i64 = sqlx::Row::get(&viewer_row, "id");

        let viewer_session_token = "sess_viewer_otp_test_token".to_string();
        sqlx::query(
            r#"
            INSERT INTO sessions (id, user_id, email, role, expires_at)
            VALUES ($1, $2, $3, 'viewer', CURRENT_TIMESTAMP + INTERVAL '1 day')
            "#,
        )
        .bind(&viewer_session_token)
        .bind(viewer_user_id)
        .bind(VIEWER_EMAIL)
        .execute(&pool)
        .await
        .unwrap();

        // 3. Seed Admin User B
        let admin_b_row = sqlx::query(
            r#"
            INSERT INTO users (google_sub, email, name, role)
            VALUES ($1, $2, 'Test Admin B', 'admin')
            RETURNING id
            "#,
        )
        .bind(ADMIN_B_SUB)
        .bind(ADMIN_B_EMAIL)
        .fetch_one(&pool)
        .await
        .unwrap();
        let admin_b_user_id: i64 = sqlx::Row::get(&admin_b_row, "id");

        let admin_b_session_token = "sess_admin_b_otp_test_token".to_string();
        sqlx::query(
            r#"
            INSERT INTO sessions (id, user_id, email, role, expires_at)
            VALUES ($1, $2, $3, 'admin', CURRENT_TIMESTAMP + INTERVAL '1 day')
            "#,
        )
        .bind(&admin_b_session_token)
        .bind(admin_b_user_id)
        .bind(ADMIN_B_EMAIL)
        .execute(&pool)
        .await
        .unwrap();

        let system_service = SystemService::new();
        let app = create_app_with_static(
            pool.clone(),
            system_service,
            config.media_roots,
            config.cache_dir,
            Some(config.static_dir),
        );

        Self {
            app,
            pool,
            admin_user_id,
            admin_session_token,
            viewer_user_id,
            viewer_session_token,
            admin_b_user_id,
            admin_b_session_token,
        }
    }
}

#[tokio::test]
async fn test_scenario_01_authorized_admin_generates_otp() {
    let harness = TestHarness::setup().await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let res = harness.app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let resp: AdminOtpGenerateResponse = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(resp.otp.len(), 6);
    assert!(resp.otp.chars().all(|c| c.is_ascii_digit()));
    assert_eq!(resp.expires_in, 300);

    // Verify stored in DB as hash, never plaintext
    let row = sqlx::query(
        "SELECT otp_hash, salt, consumed_at FROM admin_access_otps WHERE admin_user_id = $1",
    )
    .bind(harness.admin_user_id)
    .fetch_one(&harness.pool)
    .await
    .unwrap();

    let hash: String = sqlx::Row::get(&row, "otp_hash");
    let salt: String = sqlx::Row::get(&row, "salt");
    let consumed_at: Option<chrono::DateTime<chrono::Utc>> = sqlx::Row::get(&row, "consumed_at");

    assert_ne!(hash, resp.otp);
    assert!(!salt.is_empty());
    assert!(consumed_at.is_none());
}

#[tokio::test]
async fn test_scenario_02_unauthenticated_user_cannot_generate_otp() {
    let harness = TestHarness::setup().await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_scenario_03_non_admin_cannot_generate_otp() {
    let harness = TestHarness::setup().await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.viewer_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let res = harness.app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn test_scenario_04_06_otp_succeeds_once_and_mints_admin_session() {
    let harness = TestHarness::setup().await;

    // 1. Generate OTP
    let gen_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let gen_res = harness.app.clone().oneshot(gen_req).await.unwrap();
    let bytes = gen_res.into_body().collect().await.unwrap().to_bytes();
    let gen_json: AdminOtpGenerateResponse = serde_json::from_slice(&bytes).unwrap();
    let otp = gen_json.otp;

    // 2. Redeem OTP on unauthenticated client
    let verify_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp)))
        .unwrap();

    let verify_res = harness.app.clone().oneshot(verify_req).await.unwrap();
    assert_eq!(verify_res.status(), StatusCode::OK);

    // Verify Set-Cookie header contains session_token
    let cookie_hdr = verify_res
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|v| v.to_str().ok())
        .unwrap();
    assert!(cookie_hdr.contains("session_token=sess_"));

    let v_bytes = verify_res.into_body().collect().await.unwrap().to_bytes();
    let v_json: AdminOtpVerifyResponse = serde_json::from_slice(&v_bytes).unwrap();
    assert!(v_json.success);
    assert!(v_json.admin);
    assert!(v_json.session_token.is_some());

    // 3. Verify OTP is atomically marked consumed in DB
    let consumed: Option<chrono::DateTime<chrono::Utc>> =
        sqlx::query_scalar("SELECT consumed_at FROM admin_access_otps WHERE admin_user_id = $1")
            .bind(harness.admin_user_id)
            .fetch_one(&harness.pool)
            .await
            .unwrap();
    assert!(consumed.is_some());
}

#[tokio::test]
async fn test_scenario_07_reusing_consumed_otp_fails() {
    let harness = TestHarness::setup().await;

    // Generate OTP
    let gen_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let gen_res = harness.app.clone().oneshot(gen_req).await.unwrap();
    let bytes = gen_res.into_body().collect().await.unwrap().to_bytes();
    let gen_json: AdminOtpGenerateResponse = serde_json::from_slice(&bytes).unwrap();
    let otp = gen_json.otp;

    // First redemption -> 200 OK
    let req1 = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp)))
        .unwrap();
    let res1 = harness.app.clone().oneshot(req1).await.unwrap();
    assert_eq!(res1.status(), StatusCode::OK);

    // Second redemption attempt -> 401 UNAUTHORIZED
    let req2 = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp)))
        .unwrap();
    let res2 = harness.app.clone().oneshot(req2).await.unwrap();
    assert_eq!(res2.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_scenario_08_expired_otp_fails() {
    let harness = TestHarness::setup().await;

    // Generate OTP
    let gen_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let gen_res = harness.app.clone().oneshot(gen_req).await.unwrap();
    let bytes = gen_res.into_body().collect().await.unwrap().to_bytes();
    let gen_json: AdminOtpGenerateResponse = serde_json::from_slice(&bytes).unwrap();
    let otp = gen_json.otp;

    // Fast-forward expiry into the past
    sqlx::query(
        "UPDATE admin_access_otps SET expires_at = CURRENT_TIMESTAMP - INTERVAL '10 seconds' WHERE admin_user_id = $1",
    )
    .bind(harness.admin_user_id)
    .execute(&harness.pool)
    .await
    .unwrap();

    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp)))
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_scenario_09_incorrect_otp_fails() {
    let harness = TestHarness::setup().await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(r#"{"otp":"999999"}"#))
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_scenario_10_admin_a_cannot_redeem_admin_b_otp() {
    let harness = TestHarness::setup().await;

    // Admin A generates OTP
    let gen_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let gen_res = harness.app.clone().oneshot(gen_req).await.unwrap();
    let bytes = gen_res.into_body().collect().await.unwrap().to_bytes();
    let gen_json: AdminOtpGenerateResponse = serde_json::from_slice(&bytes).unwrap();
    let otp_a = gen_json.otp;

    // Admin B attempts to redeem Admin A's OTP while authenticated as Admin B
    let req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/verify")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_b_session_token),
        )
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp_a)))
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Verify Admin A's OTP is still unconsumed
    let consumed: Option<chrono::DateTime<chrono::Utc>> =
        sqlx::query_scalar("SELECT consumed_at FROM admin_access_otps WHERE admin_user_id = $1")
            .bind(harness.admin_user_id)
            .fetch_one(&harness.pool)
            .await
            .unwrap();
    assert!(consumed.is_none());
}

#[tokio::test]
async fn test_scenario_11_generating_new_otp_invalidates_previous_unused() {
    let harness = TestHarness::setup().await;

    // 1. Generate OTP 1
    let gen1_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let gen1_res = harness.app.clone().oneshot(gen1_req).await.unwrap();
    let bytes1 = gen1_res.into_body().collect().await.unwrap().to_bytes();
    let otp1 = serde_json::from_slice::<AdminOtpGenerateResponse>(&bytes1)
        .unwrap()
        .otp;

    // Allow timestamp progression for rate-limiting
    sqlx::query(
        "UPDATE admin_access_otps SET created_at = CURRENT_TIMESTAMP - INTERVAL '5 seconds' WHERE admin_user_id = $1",
    )
    .bind(harness.admin_user_id)
    .execute(&harness.pool)
    .await
    .unwrap();

    // 2. Generate OTP 2
    let gen2_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let gen2_res = harness.app.clone().oneshot(gen2_req).await.unwrap();
    let bytes2 = gen2_res.into_body().collect().await.unwrap().to_bytes();
    let otp2 = serde_json::from_slice::<AdminOtpGenerateResponse>(&bytes2)
        .unwrap()
        .otp;

    // OTP 1 must now be invalidated
    let verify1_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp1)))
        .unwrap();
    let verify1_res = harness.app.clone().oneshot(verify1_req).await.unwrap();
    assert_eq!(verify1_res.status(), StatusCode::UNAUTHORIZED);

    // OTP 2 must succeed
    let verify2_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp2)))
        .unwrap();
    let verify2_res = harness.app.clone().oneshot(verify2_req).await.unwrap();
    assert_eq!(verify2_res.status(), StatusCode::OK);
}

#[tokio::test]
async fn test_scenario_12_concurrent_redemption_atomic_single_use() {
    let harness = TestHarness::setup().await;

    // Generate OTP
    let gen_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let gen_res = harness.app.clone().oneshot(gen_req).await.unwrap();
    let bytes = gen_res.into_body().collect().await.unwrap().to_bytes();
    let otp = serde_json::from_slice::<AdminOtpGenerateResponse>(&bytes)
        .unwrap()
        .otp;

    // Spawn 2 concurrent requests
    let app1 = harness.app.clone();
    let app2 = harness.app.clone();
    let otp_clone1 = otp.clone();
    let otp_clone2 = otp.clone();

    let task1 = tokio::spawn(async move {
        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/otp/verify")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp_clone1)))
            .unwrap();
        app1.oneshot(req).await.unwrap().status()
    });

    let task2 = tokio::spawn(async move {
        let req = Request::builder()
            .method("POST")
            .uri("/api/admin/otp/verify")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp_clone2)))
            .unwrap();
        app2.oneshot(req).await.unwrap().status()
    });

    let (res1, res2) = tokio::join!(task1, task2);
    let s1 = res1.unwrap();
    let s2 = res2.unwrap();

    // Exactly one must succeed with 200, the other must fail with 401
    assert!(
        (s1 == StatusCode::OK && s2 == StatusCode::UNAUTHORIZED)
            || (s1 == StatusCode::UNAUTHORIZED && s2 == StatusCode::OK),
        "Expected exactly one 200 and one 401, got {} and {}",
        s1,
        s2
    );
}

#[tokio::test]
async fn test_scenario_13_revoke_invalidates_outstanding_otps() {
    let harness = TestHarness::setup().await;

    // 1. Generate OTP
    let gen_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/generate")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let gen_res = harness.app.clone().oneshot(gen_req).await.unwrap();
    let bytes = gen_res.into_body().collect().await.unwrap().to_bytes();
    let otp = serde_json::from_slice::<AdminOtpGenerateResponse>(&bytes)
        .unwrap()
        .otp;

    // 2. Revoke OTPs
    let revoke_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/revoke")
        .header(
            header::COOKIE,
            format!("session_token={}", harness.admin_session_token),
        )
        .body(Body::empty())
        .unwrap();

    let revoke_res = harness.app.clone().oneshot(revoke_req).await.unwrap();
    assert_eq!(revoke_res.status(), StatusCode::OK);

    // 3. Verify redemption fails
    let verify_req = Request::builder()
        .method("POST")
        .uri("/api/admin/otp/verify")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(format!(r#"{{"otp":"{}"}}"#, otp)))
        .unwrap();

    let verify_res = harness.app.clone().oneshot(verify_req).await.unwrap();
    assert_eq!(verify_res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_scenario_15_legacy_static_pin_endpoints_return_gone() {
    let harness = TestHarness::setup().await;

    // 1. POST /api/auth/login-pin -> 410 Gone
    let login_pin_req = Request::builder()
        .method("POST")
        .uri("/api/auth/login-pin")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(r#"{"pin":"97531"}"#))
        .unwrap();

    let login_res = harness.app.clone().oneshot(login_pin_req).await.unwrap();
    assert_eq!(login_res.status(), StatusCode::GONE);

    // 2. POST /api/admin/pin -> 410 Gone
    let admin_pin_req = Request::builder()
        .method("POST")
        .uri("/api/admin/pin")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(r#"{"new_pin":"987654"}"#))
        .unwrap();

    let pin_res = harness.app.clone().oneshot(admin_pin_req).await.unwrap();
    assert_eq!(pin_res.status(), StatusCode::GONE);

    // 3. GET /api/admin/status reports has_pin: false
    let status_req = Request::builder()
        .uri("/api/admin/status")
        .body(Body::empty())
        .unwrap();

    let status_res = harness.app.clone().oneshot(status_req).await.unwrap();
    assert_eq!(status_res.status(), StatusCode::OK);
    let s_bytes = status_res.into_body().collect().await.unwrap().to_bytes();
    let s_json: AdminStatusResponse = serde_json::from_slice(&s_bytes).unwrap();
    assert!(!s_json.has_pin);
}
