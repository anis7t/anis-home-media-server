use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    config::AppConfig,
    create_app, db,
    models::movie::{MovieDetailsResponse, MovieListResponse},
    models::system::SystemTelemetryResponse,
    services::system_service::SystemService,
};
use tower::ServiceExt;

async fn setup_test_app() -> axum::Router {
    let config = AppConfig::from_env();
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();
    create_app(pool, system_service, config.media_roots)
}

#[tokio::test]
async fn test_health_endpoints() {
    let app = setup_test_app().await;

    // Test /health
    let req = Request::builder()
        .uri("/health")
        .body(Body::empty())
        .unwrap();

    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["status"], "healthy");
    assert_eq!(json["engine"], "rust");

    // Test /api/health
    let req_api = Request::builder()
        .uri("/api/health")
        .body(Body::empty())
        .unwrap();

    let res_api = app.oneshot(req_api).await.unwrap();
    assert_eq!(res_api.status(), StatusCode::OK);
}

#[tokio::test]
async fn test_system_status_endpoint() {
    let app = setup_test_app().await;

    let req = Request::builder()
        .uri("/api/system-status")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let telemetry: SystemTelemetryResponse = serde_json::from_slice(&bytes)
        .expect("Response does not conform to SystemTelemetryResponse schema");

    // Verify key fields
    assert!(telemetry.cpu.cores > 0);
    assert!(telemetry.memory.total > 0);
    assert!(!telemetry.storage.label.is_empty());
}

#[tokio::test]
async fn test_movies_list_endpoint() {
    let app = setup_test_app().await;

    let req = Request::builder()
        .uri("/api/movies")
        .header("x-device-id", "test_rust_client")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let list: MovieListResponse = serde_json::from_slice(&bytes)
        .expect("Response does not conform to MovieListResponse schema");

    assert_eq!(list.movies.len(), list.total);
    assert!(list.total > 0, "Expected movies in database");

    // Assert that each movie has required fields
    for m in &list.movies {
        assert!(!m.filename.is_empty());
        assert!(!m.title.is_empty());
        assert!(m.percent >= 0.0 && m.percent <= 100.0);
    }
}

#[tokio::test]
async fn test_movie_details_endpoint() {
    let app = setup_test_app().await;

    // First retrieve list to get a valid filename
    let req_list = Request::builder()
        .uri("/api/movies")
        .body(Body::empty())
        .unwrap();

    let res_list = app.clone().oneshot(req_list).await.unwrap();
    let bytes_list = res_list.into_body().collect().await.unwrap().to_bytes();
    let list: MovieListResponse = serde_json::from_slice(&bytes_list).unwrap();
    let sample = list
        .movies
        .iter()
        .find(|m| !m.filename.contains('/') && !m.filename.contains('\\'))
        .unwrap_or(&list.movies[0]);

    // Query details for this sample movie (encoding spaces for URI)
    let encoded_filename = sample.filename.replace(' ', "%20");
    let req_details = Request::builder()
        .uri(format!("/api/movie/{}", encoded_filename))
        .body(Body::empty())
        .unwrap();

    let res_details = app.clone().oneshot(req_details).await.unwrap();
    assert_eq!(res_details.status(), StatusCode::OK);

    let bytes_details = res_details.into_body().collect().await.unwrap().to_bytes();
    let details: MovieDetailsResponse = serde_json::from_slice(&bytes_details)
        .expect("Response does not conform to MovieDetailsResponse schema");

    assert_eq!(details.movie.filename, sample.filename);
    assert!(!details.movie.title.is_empty());
    assert!(details.specs.container.is_some());

    // Query non-existent movie -> expect 404
    let req_not_found = Request::builder()
        .uri("/api/movie/definitely_not_a_real_movie_9999.mp4")
        .body(Body::empty())
        .unwrap();

    let res_not_found = app.oneshot(req_not_found).await.unwrap();
    assert_eq!(res_not_found.status(), StatusCode::NOT_FOUND);
}
