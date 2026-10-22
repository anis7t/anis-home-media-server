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
use std::fs;
use std::path::PathBuf;
use tower::ServiceExt;

/// Rows this suite owns. They are removed during setup (so a previous run
/// that failed before its teardown cannot poison this one) and again during
/// teardown (so the test database holds no residue).
const TEST_USER_SUB: &str = "sub_phone_user";
const TEST_SESSION_ID: &str = "sess_phone_device_12345";

struct TestContext {
    app: axum::Router,
    pool: sqlx::PgPool,
    temp_dir: PathBuf,
    /// The `admin_pin` setting as it was before this context touched it, so
    /// teardown can put it back exactly as it found it. `None` means the key
    /// was absent, and must be deleted again rather than restored.
    original_admin_pin: Option<String>,
}

impl TestContext {
    async fn new() -> Self {
        dotenvy::dotenv().ok();
        let config = media_server_api::test_support::test_config().await;
        let pool = db::create_pool(&config.database_url)
            .await
            .expect("Failed to connect to test db");

        let temp_dir = std::env::temp_dir().join(format!("ms_auth_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::create_dir_all(&temp_dir);

        let media_dir = temp_dir.join("media");
        let cache_dir = temp_dir.join("cache");
        fs::create_dir_all(&media_dir).unwrap();
        fs::create_dir_all(&cache_dir).unwrap();

        // Setup-time cleanup. A previous run that failed before its teardown
        // leaves these rows behind, and a plain INSERT would then fail with
        // `23505 duplicate key value violates unique constraint`. The QR
        // flow test was exactly that failure, and it was not idempotent: it
        // passed once and then failed on every subsequent run.
        Self::purge_test_rows(&pool).await;

        // Remember the admin PIN before overwriting it, so teardown can put
        // it back rather than assuming a value.
        let original_admin_pin: Option<String> =
            sqlx::query_scalar("SELECT value FROM settings WHERE key = 'admin_pin'")
                .fetch_optional(&pool)
                .await
                .unwrap();

        // Ensure admin PIN is configured for test context
        sqlx::query(
            "INSERT INTO settings (key, value) VALUES ('admin_pin', '97531') ON CONFLICT (key) DO UPDATE SET value = '97531'"
        )
        .execute(&pool)
        .await
        .unwrap();

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
            original_admin_pin,
        }
    }

    /// Remove every row this suite owns.
    async fn purge_test_rows(pool: &sqlx::PgPool) {
        // The session references the user, so it goes first.
        let _ = sqlx::query("DELETE FROM sessions WHERE id = $1")
            .bind(TEST_SESSION_ID)
            .execute(pool)
            .await;
        let _ = sqlx::query("DELETE FROM users WHERE google_sub = $1")
            .bind(TEST_USER_SUB)
            .execute(pool)
            .await;
        // Pairing rows left behind by an earlier run that failed before its
        // teardown. Only *expired* sessions are removed: a live pairing
        // session belongs to whichever test is running right now, and the
        // Rust harness runs the tests in this binary in parallel.
        let _ = sqlx::query("DELETE FROM device_pair_sessions WHERE expires_at < CURRENT_TIMESTAMP")
            .execute(pool)
            .await;
    }

    /// Explicit teardown hook (AGENTS.md s9: a suite that writes rows must
    /// delete them and leave no phantom records behind).
    ///
    /// The `Drop` impl cannot do this: it is synchronous and the database
    /// calls are async. Takes `&self` so a caller can assert on the
    /// database state *after* the teardown has run.
    async fn teardown(&self) {
        Self::purge_test_rows(&self.pool).await;

        // Put the admin PIN back exactly as it was found.
        match self.original_admin_pin.as_deref() {
            Some(value) => {
                let _ = sqlx::query(
                    "INSERT INTO settings (key, value) VALUES ('admin_pin', $1) ON CONFLICT (key) DO UPDATE SET value = $1",
                )
                .bind(value)
                .execute(&self.pool)
                .await;
            }
            None => {
                let _ = sqlx::query("DELETE FROM settings WHERE key = 'admin_pin'")
                    .execute(&self.pool)
                    .await;
            }
        }
    }
}

impl Drop for TestContext {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.temp_dir);
    }
}

#[tokio::test]
async fn test_auth_me_unauthenticated_returns_authenticated_false() {
    let ctx = TestContext::new().await;

    let req = Request::builder()
        .method("GET")
        .uri("/api/auth/me")
        .body(Body::empty())
        .unwrap();

    let resp = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["authenticated"], false);
}

#[tokio::test]
async fn test_allowlist_endpoints_and_validation() {
    let ctx = TestContext::new().await;

    // GET allowlist
    let req_get = Request::builder()
        .method("GET")
        .uri("/api/auth/allowlist")
        .header("X-Admin-Pin", "97531")
        .body(Body::empty())
        .unwrap();

    let resp_get = ctx.app.clone().oneshot(req_get).await.unwrap();
    assert_eq!(resp_get.status(), StatusCode::OK);
    let body_get: Value = serde_json::from_slice(&resp_get.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(body_get["stored"].is_array());
    assert!(body_get["environment"].is_array());
    assert!(body_get["effective"].is_array());

    // POST allowlist valid
    let req_post = Request::builder()
        .method("POST")
        .uri("/api/auth/allowlist")
        .header("X-Admin-Pin", "97531")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "emails": ["Operator@Example.com", "second@example.com"] }).to_string()))
        .unwrap();

    let resp_post = ctx.app.clone().oneshot(req_post).await.unwrap();
    assert_eq!(resp_post.status(), StatusCode::OK);
    let body_post: Value = serde_json::from_slice(&resp_post.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body_post["success"], true);

    let stored = body_post["stored"].as_array().unwrap();
    assert!(stored.iter().any(|e| e == "operator@example.com"));

    // POST allowlist invalid (non-string entries) -> 400
    let req_bad = Request::builder()
        .method("POST")
        .uri("/api/auth/allowlist")
        .header("X-Admin-Pin", "97531")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "emails": [123, 456] }).to_string()))
        .unwrap();
    let resp_bad = ctx.app.clone().oneshot(req_bad).await.unwrap();
    assert_eq!(resp_bad.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_tokens_bearer_token_cannot_mint_or_manage_tokens() {
    let ctx = TestContext::new().await;

    let bearer = "Bearer ms_fake1234567890abcdef1234567890abcdef";

    // 1. Bearer cannot list tokens
    let req_list = Request::builder()
        .method("GET")
        .uri("/api/auth/tokens")
        .header(header::AUTHORIZATION, bearer)
        .body(Body::empty())
        .unwrap();
    let resp_list = ctx.app.clone().oneshot(req_list).await.unwrap();
    assert_eq!(resp_list.status(), StatusCode::FORBIDDEN);

    // 2. Bearer cannot mint tokens
    let req_mint = Request::builder()
        .method("POST")
        .uri("/api/auth/tokens")
        .header(header::AUTHORIZATION, bearer)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "label": "Another TV" }).to_string()))
        .unwrap();
    let resp_mint = ctx.app.clone().oneshot(req_mint).await.unwrap();
    assert_eq!(resp_mint.status(), StatusCode::FORBIDDEN);

    // 3. Bearer cannot revoke tokens
    let req_revoke = Request::builder()
        .method("DELETE")
        .uri("/api/auth/tokens/1")
        .header(header::AUTHORIZATION, bearer)
        .body(Body::empty())
        .unwrap();
    let resp_revoke = ctx.app.clone().oneshot(req_revoke).await.unwrap();
    assert_eq!(resp_revoke.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn test_tokens_minting_validation_and_lifecycle() {
    let ctx = TestContext::new().await;

    // A. Label is required
    let req_no_label = Request::builder()
        .method("POST")
        .uri("/api/auth/tokens")
        .header("X-Admin-Pin", "97531")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({}).to_string()))
        .unwrap();
    let resp_no_label = ctx.app.clone().oneshot(req_no_label).await.unwrap();
    assert_eq!(resp_no_label.status(), StatusCode::BAD_REQUEST);

    // B. Negative validity days is rejected
    let req_bad_validity = Request::builder()
        .method("POST")
        .uri("/api/auth/tokens")
        .header("X-Admin-Pin", "97531")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "label": "TV", "validity_days": -10 }).to_string()))
        .unwrap();
    let resp_bad_validity = ctx.app.clone().oneshot(req_bad_validity).await.unwrap();
    assert_eq!(resp_bad_validity.status(), StatusCode::BAD_REQUEST);

    // C. Valid minting with Admin PIN
    let req_valid = Request::builder()
        .method("POST")
        .uri("/api/auth/tokens")
        .header("X-Admin-Pin", "97531")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "label": "Living Room TV" }).to_string()))
        .unwrap();
    let resp_valid = ctx.app.clone().oneshot(req_valid).await.unwrap();
    assert_eq!(resp_valid.status(), StatusCode::CREATED);

    let bytes = resp_valid.into_body().collect().await.unwrap().to_bytes();
    let body_valid: Value = serde_json::from_slice(&bytes).unwrap();
    let token_str = body_valid["token"].as_str().unwrap();
    assert!(token_str.starts_with("ms_"));
    assert_eq!(body_valid["label"], "Living Room TV");
    assert!(body_valid["pairing_url"].as_str().unwrap().contains("#token="));
    let token_id = body_valid["id"].as_i64().unwrap();

    // D. List tokens
    let req_list = Request::builder()
        .method("GET")
        .uri("/api/auth/tokens")
        .header("X-Admin-Pin", "97531")
        .body(Body::empty())
        .unwrap();
    let resp_list = ctx.app.clone().oneshot(req_list).await.unwrap();
    assert_eq!(resp_list.status(), StatusCode::OK);
    let body_list: Value = serde_json::from_slice(&resp_list.into_body().collect().await.unwrap().to_bytes()).unwrap();
    let tokens = body_list["tokens"].as_array().unwrap();
    assert!(tokens.iter().any(|t| t["id"] == token_id));

    // E. Revoke token
    let req_revoke = Request::builder()
        .method("DELETE")
        .uri(format!("/api/auth/tokens/{}", token_id))
        .header("X-Admin-Pin", "97531")
        .body(Body::empty())
        .unwrap();
    let resp_revoke = ctx.app.clone().oneshot(req_revoke).await.unwrap();
    assert_eq!(resp_revoke.status(), StatusCode::OK);
    let body_revoke: Value = serde_json::from_slice(&resp_revoke.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body_revoke["revoked"], token_id);
}

#[tokio::test]
async fn test_pairing_device_lifecycle() {
    let ctx = TestContext::new().await;

    // 1. Create a user
    let user_row = sqlx::query(
        r#"
        INSERT INTO users (google_sub, email, name, role, created_at)
        VALUES ('sub-pair-test', 'pairtest@example.com', 'Pair User', 'viewer', CURRENT_TIMESTAMP)
        ON CONFLICT (google_sub) DO UPDATE SET email = EXCLUDED.email
        RETURNING id
        "#,
    )
    .fetch_one(&ctx.pool)
    .await
    .unwrap();
    let user_id: i64 = sqlx::Row::get(&user_row, "id");

    // 2. Mint token for this user
    let minted = media_server_api::services::auth_service::AuthService::create_token(
        &ctx.pool,
        user_id,
        "Bedroom TV",
        Some(30),
        "http://localhost:8000",
    )
    .await
    .unwrap();

    // 3. GET /auth/pair returns HTML
    let req_pair_get = Request::builder()
        .method("GET")
        .uri("/auth/pair")
        .body(Body::empty())
        .unwrap();
    let resp_pair_get = ctx.app.clone().oneshot(req_pair_get).await.unwrap();
    assert_eq!(resp_pair_get.status(), StatusCode::OK);

    // 4. POST /auth/pair with valid token exchanges for session cookie
    let form_body = format!("token={}", minted.token);
    let req_pair_post = Request::builder()
        .method("POST")
        .uri("/auth/pair")
        .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
        .body(Body::from(form_body))
        .unwrap();
    let resp_pair_post = ctx.app.clone().oneshot(req_pair_post).await.unwrap();
    assert_eq!(resp_pair_post.status(), StatusCode::TEMPORARY_REDIRECT);

    let set_cookie = resp_pair_post
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|v| v.to_str().ok())
        .expect("Must set session cookie");
    assert!(set_cookie.contains("session_token=sess_"));

    // Extract cookie value
    let cookie_val = set_cookie.split(';').next().unwrap();

    // 5. Subsequent GET /api/auth/me with session cookie recognizes user!
    let req_me = Request::builder()
        .method("GET")
        .uri("/api/auth/me")
        .header(header::COOKIE, cookie_val)
        .body(Body::empty())
        .unwrap();
    let resp_me = ctx.app.clone().oneshot(req_me).await.unwrap();
    assert_eq!(resp_me.status(), StatusCode::OK);
    let body_me: Value = serde_json::from_slice(&resp_me.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body_me["authenticated"], true);
    assert_eq!(body_me["email"], "pairtest@example.com");
    assert_eq!(body_me["name"], "Pair User");
    assert_eq!(body_me["role"], "viewer");

    // 6. POST /auth/logout clears cookie
    let req_logout = Request::builder()
        .method("POST")
        .uri("/auth/logout")
        .header(header::COOKIE, cookie_val)
        .body(Body::empty())
        .unwrap();
    let resp_logout = ctx.app.clone().oneshot(req_logout).await.unwrap();
    assert_eq!(resp_logout.status(), StatusCode::TEMPORARY_REDIRECT);
    let clear_cookie = resp_logout
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|v| v.to_str().ok())
        .unwrap();
    assert!(clear_cookie.contains("Max-Age=0"));

    // Teardown: the user row and everything that cascades from it (the
    // minted device token and the exchanged session) must not survive.
    let _ = sqlx::query("DELETE FROM users WHERE google_sub = 'sub-pair-test'")
        .execute(&ctx.pool)
        .await;

    ctx.teardown().await;
}

#[tokio::test]
async fn qr_device_auth_flow_test() {
    let ctx = TestContext::new().await;

    // 1. Create a user and an active session for the phone
    //
    // Idempotent on purpose: a plain INSERT made this test fail with
    // `23505 duplicate key value violates unique constraint
    // "users_google_sub_key"` on every run after the first, because the
    // previous run's row was never removed. The setup-time purge in
    // `TestContext::new()` prevents that too, but the statement should not
    // depend on it.
    let user_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO users (google_sub, email, name, role)
        VALUES ($1, 'phone@example.com', 'Phone User', 'viewer')
        ON CONFLICT (google_sub) DO UPDATE SET email = EXCLUDED.email
        RETURNING id
        "#,
    )
    .bind(TEST_USER_SUB)
    .fetch_one(&ctx.pool)
    .await
    .unwrap();

    let phone_session_token = TEST_SESSION_ID;
    sqlx::query(
        r#"
        INSERT INTO sessions (id, user_id, email, role, expires_at)
        VALUES ($1, $2, 'phone@example.com', 'viewer', CURRENT_TIMESTAMP + INTERVAL '1 day')
        ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id
        "#,
    )
    .bind(phone_session_token)
    .bind(user_id)
    .execute(&ctx.pool)
    .await
    .unwrap();

    let phone_cookie = format!("session_token={}", phone_session_token);

    // 2. TV creates QR pair session: POST /api/auth/qr
    let req_qr_create = Request::builder()
        .method("POST")
        .uri("/api/auth/qr")
        .body(Body::empty())
        .unwrap();
    let resp_qr_create = ctx.app.clone().oneshot(req_qr_create).await.unwrap();
    assert_eq!(resp_qr_create.status(), StatusCode::OK);

    // The session secret must be delivered only as a path-scoped, HttpOnly
    // cookie: `finalize` is unauthenticated, so this cookie is the sole proof
    // that the caller is the device that created the session.
    let qr_secret_cookie = resp_qr_create
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|v| v.to_str().ok())
        .expect("POST /api/auth/qr must set the ms_qr_secret cookie")
        .to_string();
    assert!(qr_secret_cookie.starts_with("ms_qr_secret="));
    assert!(qr_secret_cookie.contains("; HttpOnly"));
    assert!(qr_secret_cookie.contains("SameSite=Lax"));
    assert!(qr_secret_cookie.contains("Max-Age=130"));
    assert!(!qr_secret_cookie.contains("session_token="));
    let qr_secret_cookie_val = qr_secret_cookie
        .split(';')
        .next()
        .unwrap()
        .to_string();
    let qr_secret = qr_secret_cookie_val
        .trim_start_matches("ms_qr_secret=")
        .to_string();
    assert!(!qr_secret.is_empty());

    let body_bytes = resp_qr_create.into_body().collect().await.unwrap().to_bytes();
    // The secret must not be readable from the page: it is not in the body.
    assert!(
        !String::from_utf8_lossy(&body_bytes).contains(&qr_secret),
        "the response body must not contain the pairing secret"
    );
    let body_create: Value = serde_json::from_slice(&body_bytes).unwrap();
    let qr_id = body_create["qr_id"].as_str().expect("qr_id must be a string");
    let code = body_create["code"].as_str().expect("code must be a string");
    let sig = body_create["sig"].as_str().expect("sig must be a string");
    assert_eq!(code.len(), 5);
    assert!(body_create["qr_url"].as_str().unwrap().contains("/remotelogin"));
    assert!(
        qr_secret_cookie.contains(&format!("Path=/api/auth/qr/{}", qr_id)),
        "the secret cookie must be scoped to this session's own path"
    );

    // 3. TV checks status: GET /api/auth/qr/{qr_id}/status -> "pending"
    let req_status_1 = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/status", qr_id))
        .body(Body::empty())
        .unwrap();
    let resp_status_1 = ctx.app.clone().oneshot(req_status_1).await.unwrap();
    assert_eq!(resp_status_1.status(), StatusCode::OK);
    let body_status_1: Value =
        serde_json::from_slice(&resp_status_1.into_body().collect().await.unwrap().to_bytes())
            .unwrap();
    assert_eq!(body_status_1["status"], "pending");

    // 4. Phone manual entry flow: POST /api/auth/qr/lookup with the 5-char code
    let req_lookup_invalid = Request::builder()
        .method("POST")
        .uri("/api/auth/qr/lookup")
        .header(header::COOKIE, &phone_cookie)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "code": "ZZZZZ" }).to_string()))
        .unwrap();
    let resp_lookup_invalid = ctx.app.clone().oneshot(req_lookup_invalid).await.unwrap();
    assert_eq!(resp_lookup_invalid.status(), StatusCode::NOT_FOUND);

    let req_lookup_valid = Request::builder()
        .method("POST")
        .uri("/api/auth/qr/lookup")
        .header(header::COOKIE, &phone_cookie)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "code": code }).to_string()))
        .unwrap();
    let resp_lookup_valid = ctx.app.clone().oneshot(req_lookup_valid).await.unwrap();
    assert_eq!(resp_lookup_valid.status(), StatusCode::OK);
    let body_lookup: Value =
        serde_json::from_slice(&resp_lookup_valid.into_body().collect().await.unwrap().to_bytes())
            .unwrap();
    assert_eq!(body_lookup["qr_id"], qr_id);

    // 5. Phone confirms pairing: POST /api/auth/qr/{qr_id}/confirm
    let req_confirm = Request::builder()
        .method("POST")
        .uri(format!("/api/auth/qr/{}/confirm", qr_id))
        .header(header::COOKIE, &phone_cookie)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({
                "code": code,
                "sig": sig,
                "device_name": "Living Room TV"
            })
            .to_string(),
        ))
        .unwrap();
    let resp_confirm = ctx.app.clone().oneshot(req_confirm).await.unwrap();
    assert_eq!(resp_confirm.status(), StatusCode::OK);

    // 6. TV status is now "confirmed"
    let req_status_2 = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/status", qr_id))
        .body(Body::empty())
        .unwrap();
    let resp_status_2 = ctx.app.clone().oneshot(req_status_2).await.unwrap();
    assert_eq!(resp_status_2.status(), StatusCode::OK);
    let body_status_2: Value =
        serde_json::from_slice(&resp_status_2.into_body().collect().await.unwrap().to_bytes())
            .unwrap();
    assert_eq!(body_status_2["status"], "confirmed");

    // 7. Finalize is bound to the waiting device. The refusals come first,
    // because a happy-path-only test would pass against the pre-fix code.
    //
    // 7a. Holding only the qr_id (the pre-fix requirement) must be refused.
    let req_finalize_no_secret = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .body(Body::empty())
        .unwrap();
    let resp_no_secret = ctx.app.clone().oneshot(req_finalize_no_secret).await.unwrap();
    assert_eq!(resp_no_secret.status(), StatusCode::FORBIDDEN);
    assert!(
        resp_no_secret.headers().get(header::SET_COOKIE).is_none(),
        "a refused finalize must not issue any cookie"
    );

    // 7b. A wrong secret for the right session must be refused.
    let req_finalize_wrong_secret = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header(
            header::COOKIE,
            "ms_qr_secret=0000000000000000000000000000000000000000000000000000000000000000",
        )
        .body(Body::empty())
        .unwrap();
    let resp_wrong_secret = ctx
        .app
        .clone()
        .oneshot(req_finalize_wrong_secret)
        .await
        .unwrap();
    assert_eq!(resp_wrong_secret.status(), StatusCode::FORBIDDEN);
    assert!(resp_wrong_secret
        .headers()
        .get(header::SET_COOKIE)
        .is_none());

    // 7c. Another session's valid secret must not unlock this session.
    let req_other_create = Request::builder()
        .method("POST")
        .uri("/api/auth/qr")
        .body(Body::empty())
        .unwrap();
    let resp_other_create = ctx.app.clone().oneshot(req_other_create).await.unwrap();
    assert_eq!(resp_other_create.status(), StatusCode::OK);
    let other_secret_cookie = resp_other_create
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|v| v.to_str().ok())
        .expect("second create must set its own secret cookie")
        .split(';')
        .next()
        .unwrap()
        .to_string();
    let other_body: Value = serde_json::from_slice(
        &resp_other_create
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes(),
    )
    .unwrap();
    let other_qr_id = other_body["qr_id"].as_str().unwrap();

    let req_finalize_cross_session = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header(header::COOKIE, &other_secret_cookie)
        .body(Body::empty())
        .unwrap();
    let resp_cross_session = ctx
        .app
        .clone()
        .oneshot(req_finalize_cross_session)
        .await
        .unwrap();
    assert_eq!(resp_cross_session.status(), StatusCode::FORBIDDEN);
    assert!(resp_cross_session
        .headers()
        .get(header::SET_COOKIE)
        .is_none());

    // The second session served its purpose; remove it so the residue check
    // below can be exact (an unconfirmed session has no user_id to cascade on).
    let _ = sqlx::query("DELETE FROM device_pair_sessions WHERE id = $1")
        .bind(other_qr_id)
        .execute(&ctx.pool)
        .await;

    // 7d. The creator, presenting its own secret, finalizes successfully.
    let req_finalize = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/finalize", qr_id))
        .header(header::COOKIE, &qr_secret_cookie_val)
        .body(Body::empty())
        .unwrap();
    let resp_finalize = ctx.app.clone().oneshot(req_finalize).await.unwrap();
    assert_eq!(resp_finalize.status(), StatusCode::TEMPORARY_REDIRECT);

    let tv_cookie_header = resp_finalize
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|v| v.to_str().ok())
        .expect("Finalize must set session_token cookie")
        .to_string();
    assert!(tv_cookie_header.contains("session_token=sess_"));
    let tv_cookie_val = tv_cookie_header.split(';').next().unwrap();

    // The used secret must be cleared with the same Path that set it.
    let cleared_secret = resp_finalize
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find(|c| c.starts_with("ms_qr_secret=;"));
    let cleared_secret = cleared_secret.expect("finalize must clear the used pair secret");
    assert!(cleared_secret.contains("Max-Age=0"));
    assert!(cleared_secret.contains(&format!("Path=/api/auth/qr/{}", qr_id)));

    // 8. TV uses session cookie to access /api/auth/me
    let req_tv_me = Request::builder()
        .method("GET")
        .uri("/api/auth/me")
        .header(header::COOKIE, tv_cookie_val)
        .body(Body::empty())
        .unwrap();
    let resp_tv_me = ctx.app.clone().oneshot(req_tv_me).await.unwrap();
    assert_eq!(resp_tv_me.status(), StatusCode::OK);
    let body_tv_me: Value =
        serde_json::from_slice(&resp_tv_me.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body_tv_me["authenticated"], true);
    assert_eq!(body_tv_me["email"], "phone@example.com");
    assert_eq!(body_tv_me["name"], "Phone User");

    // 9. Teardown: the suite must leave no phantom rows behind (AGENTS.md s9).
    // Assert it, rather than trusting the teardown hook.
    ctx.teardown().await;

    let residue: i64 = sqlx::query_scalar(
        r#"
        SELECT (SELECT count(*) FROM users WHERE google_sub = $1)
             + (SELECT count(*) FROM sessions WHERE id = $2 OR email = 'phone@example.com')
             + (SELECT count(*) FROM device_pair_sessions WHERE id = $3)
        "#,
    )
    .bind(TEST_USER_SUB)
    .bind(TEST_SESSION_ID)
    .bind(qr_id)
    .fetch_one(&ctx.pool)
    .await
    .unwrap();
    assert_eq!(residue, 0, "the test must leave no phantom rows behind");
}

#[tokio::test]
async fn qr_create_rate_limit_test() {
    let ctx = TestContext::new().await;

    // One client, eleven rapid creates. The budget is ten per minute, so the
    // eleventh must be refused - and a refusal must say when to come back.
    const CLIENT_A: &str = "198.51.100.44";
    const CLIENT_B: &str = "198.51.100.45";

    let mut created: Vec<String> = Vec::new();
    let mut refused = 0;
    for _ in 0..11 {
        let req = Request::builder()
            .method("POST")
            .uri("/api/auth/qr")
            .header("x-forwarded-for", CLIENT_A)
            .body(Body::empty())
            .unwrap();
        let resp = ctx.app.clone().oneshot(req).await.unwrap();
        if resp.status() == StatusCode::TOO_MANY_REQUESTS {
            refused += 1;
            assert!(
                resp.headers().get(header::RETRY_AFTER).is_some(),
                "a rate-limited response must carry Retry-After"
            );
        } else {
            assert_eq!(resp.status(), StatusCode::OK);
            let body: Value =
                serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes())
                    .unwrap();
            created.push(body["qr_id"].as_str().unwrap().to_string());
        }
    }
    assert_eq!(
        created.len(),
        10,
        "the budget must be ten creates per minute"
    );
    assert_eq!(refused, 1, "the eleventh create must be refused");

    // A different client is judged on its own budget...
    let req_other = Request::builder()
        .method("POST")
        .uri("/api/auth/qr")
        .header("x-forwarded-for", CLIENT_B)
        .body(Body::empty())
        .unwrap();
    let resp_other = ctx.app.clone().oneshot(req_other).await.unwrap();
    assert_eq!(resp_other.status(), StatusCode::OK);
    let other_body: Value =
        serde_json::from_slice(&resp_other.into_body().collect().await.unwrap().to_bytes())
            .unwrap();
    created.push(other_body["qr_id"].as_str().unwrap().to_string());

    // ...and a different route does not spend this client's create budget.
    let req_status = Request::builder()
        .method("GET")
        .uri(format!("/api/auth/qr/{}/status", created[0]))
        .header("x-forwarded-for", CLIENT_A)
        .body(Body::empty())
        .unwrap();
    let resp_status = ctx.app.clone().oneshot(req_status).await.unwrap();
    assert_eq!(resp_status.status(), StatusCode::OK);

    // These sessions are unconfirmed (user_id is NULL), so deleting a test user
    // would not cascade them away: remove them explicitly.
    for id in &created {
        sqlx::query("DELETE FROM device_pair_sessions WHERE id = $1")
            .bind(id)
            .execute(&ctx.pool)
            .await
            .unwrap();
    }

    ctx.teardown().await;

    let residue: i64 =
        sqlx::query_scalar("SELECT count(*) FROM device_pair_sessions WHERE id = ANY($1)")
            .bind(created.clone())
            .fetch_one(&ctx.pool)
            .await
            .unwrap();
    assert_eq!(
        residue, 0,
        "the test must leave no phantom pair sessions behind"
    );
}
