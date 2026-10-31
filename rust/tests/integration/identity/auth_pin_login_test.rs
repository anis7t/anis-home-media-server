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
    let (app, _) = setup_test_app().await;

    // Static PIN login is retired and must return 410 Gone
    let req = Request::builder()
        .method("POST")
        .uri("/api/auth/login-pin")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(r#"{"pin":"97531"}"#))
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::GONE);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(json.get("error").is_some());
    assert!(json["error"].as_str().unwrap().contains("retired"));
}
