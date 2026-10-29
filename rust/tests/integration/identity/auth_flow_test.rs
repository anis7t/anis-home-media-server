use axum::{
    body::Body,
    extract::Request,
    http::{header, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app_full, db, services::system_service::SystemService};
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
        let _ =
            sqlx::query("DELETE FROM device_pair_sessions WHERE expires_at < CURRENT_TIMESTAMP")
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

    // This test owns `auth_allowlist` in the test database. A previous run
    // that failed before its cleanup must not decide who may sign in, so start
    // from a known-empty list.
    sqlx::query("DELETE FROM settings WHERE key = 'auth_allowlist'")
        .execute(&ctx.pool)
        .await
        .unwrap();

    // Anonymous callers are refused even when `MEDIA_SERVER_AUTH` is off.
    // The allowlist decides who may sign in, so it must never be readable or
    // writable by a visitor who is not an admin.
    let req_anon_get = Request::builder()
        .method("GET")
        .uri("/api/auth/allowlist")
        .body(Body::empty())
        .unwrap();
    let resp_anon_get = ctx.app.clone().oneshot(req_anon_get).await.unwrap();
    assert_eq!(resp_anon_get.status(), StatusCode::UNAUTHORIZED);

    let req_anon_post = Request::builder()
        .method("POST")
        .uri("/api/auth/allowlist")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({ "emails": ["attacker@example.test"] }).to_string(),
        ))
        .unwrap();
    let resp_anon_post = ctx.app.clone().oneshot(req_anon_post).await.unwrap();
    assert_eq!(resp_anon_post.status(), StatusCode::UNAUTHORIZED);

    // GET allowlist
    let req_get = Request::builder()
        .method("GET")
        .uri("/api/auth/allowlist")
        .header("X-Admin-Pin", "97531")
        .body(Body::empty())
        .unwrap();

    let resp_get = ctx.app.clone().oneshot(req_get).await.unwrap();
    assert_eq!(resp_get.status(), StatusCode::OK);
    let body_get: Value =
        serde_json::from_slice(&resp_get.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(body_get["stored"].is_array());
    assert!(body_get["environment"].is_array());
    assert!(body_get["effective"].is_array());
    // The refused anonymous POST must not have written anything.
    assert!(
        body_get["stored"]
            .as_array()
            .unwrap()
            .iter()
            .all(|e| e != "attacker@example.test"),
        "anonymous POST must not mutate the allowlist"
    );

    // POST allowlist valid
    let req_post = Request::builder()
        .method("POST")
        .uri("/api/auth/allowlist")
        .header("X-Admin-Pin", "97531")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({ "emails": ["Operator@Example.com", "second@example.com"] }).to_string(),
        ))
        .unwrap();

    let resp_post = ctx.app.clone().oneshot(req_post).await.unwrap();
    assert_eq!(resp_post.status(), StatusCode::OK);
    let body_post: Value =
        serde_json::from_slice(&resp_post.into_body().collect().await.unwrap().to_bytes()).unwrap();
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

    // Leave the test database exactly as found: this suite owns the row while
    // it runs, and the rule is zero residue (AGENTS.md s9).
    sqlx::query("DELETE FROM settings WHERE key = 'auth_allowlist'")
        .execute(&ctx.pool)
        .await
        .unwrap();
    let residue: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM settings WHERE key = 'auth_allowlist'")
            .fetch_one(&ctx.pool)
            .await
            .unwrap();
    assert_eq!(
        residue, 0,
        "allowlist fixture must not leak into the test database"
    );

    ctx.teardown().await;
}

#[tokio::test]
async fn retired_pairing_token_surface_is_gone() {
    let ctx = TestContext::new().await;

    // The long-lived pairing-token surface was retired on 2026-10-23. The
    // SPA fallback answers 404 for unmatched `/api/*` and `/auth/*` paths, so
    // these requests must not reach a handler or return the SPA shell.
    for (method, uri) in [
        ("GET", "/api/auth/tokens"),
        ("POST", "/api/auth/tokens"),
        ("DELETE", "/api/auth/tokens/1"),
        ("GET", "/auth/pair"),
        ("POST", "/auth/pair"),
    ] {
        let req = Request::builder()
            .method(method)
            .uri(uri)
            .body(Body::empty())
            .unwrap();
        let resp = ctx.app.clone().oneshot(req).await.unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::NOT_FOUND,
            "{method} {uri} must be retired"
        );
    }

    // `ensure_schema()` drops the table on every boot, including this test
    // database. A restored pre-retirement dump must not resurrect it.
    let regclass: Option<String> =
        sqlx::query_scalar("SELECT to_regclass('public.auth_tokens')::text")
            .fetch_one(&ctx.pool)
            .await
            .unwrap();
    assert!(
        regclass.is_none(),
        "auth_tokens must be dropped, found {regclass:?}"
    );

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
    let qr_secret_cookie_val = qr_secret_cookie.split(';').next().unwrap().to_string();
    let qr_secret = qr_secret_cookie_val
        .trim_start_matches("ms_qr_secret=")
        .to_string();
    assert!(!qr_secret.is_empty());

    let body_bytes = resp_qr_create
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    // The secret must not be readable from the page: it is not in the body.
    assert!(
        !String::from_utf8_lossy(&body_bytes).contains(&qr_secret),
        "the response body must not contain the pairing secret"
    );
    let body_create: Value = serde_json::from_slice(&body_bytes).unwrap();
    let qr_id = body_create["qr_id"]
        .as_str()
        .expect("qr_id must be a string");
    let code = body_create["code"].as_str().expect("code must be a string");
    assert_eq!(code.len(), 5);
    assert!(body_create["qr_url"]
        .as_str()
        .unwrap()
        .contains("/remotelogin"));
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
    let body_status_1: Value = serde_json::from_slice(
        &resp_status_1
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes(),
    )
    .unwrap();
    assert_eq!(body_status_1["status"], "pending");

    // 4. Phone manual entry flow: POST /api/auth/qr/lookup with the 5-char code.
    //
    // A deliberately *lowercase* code is sent: lookup is documented as
    // case-insensitive, and it now hashes the normalized submission, so this
    // is what proves the normalization still happens before hashing.
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
        .body(Body::from(
            json!({ "code": code.to_lowercase() }).to_string(),
        ))
        .unwrap();
    let resp_lookup_valid = ctx.app.clone().oneshot(req_lookup_valid).await.unwrap();
    assert_eq!(resp_lookup_valid.status(), StatusCode::OK);
    let body_lookup: Value = serde_json::from_slice(
        &resp_lookup_valid
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes(),
    )
    .unwrap();
    assert_eq!(body_lookup["qr_id"], qr_id);

    // 5. Phone confirms pairing: POST /api/auth/qr/{qr_id}/confirm
    //
    // Code only, and lowercase on purpose: sending `sig` as well would let a
    // broken code comparison pass, because either factor is accepted. This is
    // the assertion that the *hash* comparison works now that the plaintext
    // column is gone.
    let req_confirm = Request::builder()
        .method("POST")
        .uri(format!("/api/auth/qr/{}/confirm", qr_id))
        .header(header::COOKIE, &phone_cookie)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({
                "code": code.to_lowercase(),
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
    let body_status_2: Value = serde_json::from_slice(
        &resp_status_2
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes(),
    )
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
    let resp_no_secret = ctx
        .app
        .clone()
        .oneshot(req_finalize_no_secret)
        .await
        .unwrap();
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

    // 7c-bis. The QR-signature path must still work with no code at all: a
    // scanned QR posts `sig` alone, and that factor is independent of the
    // plaintext code column that was dropped.
    let other_sig = other_body["sig"].as_str().unwrap();
    let req_confirm_sig_only = Request::builder()
        .method("POST")
        .uri(format!("/api/auth/qr/{}/confirm", other_qr_id))
        .header(header::COOKIE, &phone_cookie)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({ "sig": other_sig, "device_name": "Bedroom TV" }).to_string(),
        ))
        .unwrap();
    let resp_confirm_sig_only = ctx.app.clone().oneshot(req_confirm_sig_only).await.unwrap();
    assert_eq!(resp_confirm_sig_only.status(), StatusCode::OK);

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
        serde_json::from_slice(&resp_tv_me.into_body().collect().await.unwrap().to_bytes())
            .unwrap();
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
