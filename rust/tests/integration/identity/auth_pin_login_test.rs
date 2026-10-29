use axum::{
    body::Body,
    http::{header, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app_with_static, db, services::system_service::SystemService};
use tower::ServiceExt;

async fn setup_test_app() -> (axum::Router, sqlx::PgPool) {
    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();
    let app = create_app_with_static(
        pool.clone(),
        system_service,
        config.media_roots,
        config.cache_dir,
        Some(config.static_dir),
    );
    (app, pool)
}

#[tokio::test]
async fn test_auth_me_reports_oauth_configured() {
    let (app, _) = setup_test_app().await;

    let req = Request::builder()
        .uri("/api/auth/me")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(json.get("oauth_configured").is_some());
    assert!(json["oauth_configured"].is_boolean());
}

#[tokio::test]
async fn test_auth_google_redirects_when_unconfigured() {
    let (app, _) = setup_test_app().await;

    let req = Request::builder()
        .uri("/auth/google")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    // If not configured, redirects to /account?error=oauth_unconfigured
    assert!(res.status().is_redirection());
    let location = res
        .headers()
        .get(header::LOCATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        location.contains("/account?error=oauth_unconfigured")
            || location.contains("accounts.google.com")
    );
}

#[tokio::test]
async fn test_login_pin_flow() {
    let (app, pool) = setup_test_app().await;

    // 1. Ensure a known PIN is configured in settings table for the test
    let test_pin = "97531";
    sqlx::query(
        r#"
        INSERT INTO settings (key, value)
        VALUES ('admin_pin', $1)
        ON CONFLICT (key) DO UPDATE SET value = $1
        "#,
    )
    .bind(test_pin)
    .execute(&pool)
    .await
    .unwrap();

    // 2. Attempt login with wrong PIN -> 401
    let wrong_req = Request::builder()
        .method("POST")
        .uri("/api/auth/login-pin")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(r#"{"pin":"wrong_pin"}"#))
        .unwrap();

    let res = app.clone().oneshot(wrong_req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // 3. Attempt login with valid PIN -> 200, Set-Cookie session_token
    let valid_req = Request::builder()
        .method("POST")
        .uri("/api/auth/login-pin")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(format!(r#"{{"pin":"{}"}}"#, test_pin)))
        .unwrap();

    let res = app.clone().oneshot(valid_req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let cookie = res
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    assert!(cookie.contains("session_token=sess_"));
    assert!(cookie.contains("Path=/"));
    assert!(cookie.contains("HttpOnly"));

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["success"], true);
    assert_eq!(json["user"]["role"], "admin");
    assert_eq!(json["user"]["is_admin"], true);

    // Extract session token
    let session_val = cookie
        .split(';')
        .find(|part| part.trim().starts_with("session_token="))
        .unwrap()
        .trim();

    // 4. Verify /api/auth/me recognizes the minted session
    let me_req = Request::builder()
        .uri("/api/auth/me")
        .header(header::COOKIE, session_val)
        .body(Body::empty())
        .unwrap();

    let me_res = app.oneshot(me_req).await.unwrap();
    assert_eq!(me_res.status(), StatusCode::OK);

    let me_bytes = me_res.into_body().collect().await.unwrap().to_bytes();
    let me_json: serde_json::Value = serde_json::from_slice(&me_bytes).unwrap();
    assert_eq!(me_json["authenticated"], true);
    assert_eq!(me_json["role"], "admin");
    assert_eq!(me_json["is_admin"], true);

    // 5. Teardown: ensure admin_pin is preserved as 97531
    let _ = sqlx::query(
        "INSERT INTO settings (key, value) VALUES ('admin_pin', '97531') ON CONFLICT (key) DO UPDATE SET value = '97531'"
    )
    .execute(&pool)
    .await;
}
