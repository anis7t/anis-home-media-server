use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    create_app, db,
    models::movie::{MovieDetailsResponse, MovieListResponse},
    models::system::SystemTelemetryResponse,
    services::system_service::SystemService,
};
use tower::ServiceExt;

struct TestApp {
    app: axum::Router,
    pool: sqlx::PgPool,
    media_roots: Vec<std::path::PathBuf>,
}

async fn setup_test_app() -> TestApp {
    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();
    let app = create_app(
        pool.clone(),
        system_service,
        config.media_roots.clone(),
        config.cache_dir,
    );
    TestApp {
        app,
        pool,
        media_roots: config.media_roots,
    }
}

/// Seed a catalog row for a real, probeable media file and return it.
///
/// The isolated test database starts empty, and these two contracts are only
/// meaningful against a genuine video file: `ffprobe` has to return real
/// container and stream values. The file comes from the read-only production
/// media roots; only the metadata is written, and only to the test database.
async fn seed_real_movie(pool: &sqlx::PgPool, media_roots: &[std::path::PathBuf]) -> String {
    media_server_api::test_support::seed_real_media_row(pool, media_roots)
        .await
        .expect("the library must offer a probeable media file for this contract")
}

#[tokio::test]
async fn test_health_endpoints() {
    let t = setup_test_app().await;
    let app = t.app;

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
    let t = setup_test_app().await;
    let app = t.app;

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
    let t = setup_test_app().await;
    let seeded = seed_real_movie(&t.pool, &t.media_roots).await;
    let app = t.app;

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
    assert!(
        list.movies.iter().any(|m| m.filename == seeded),
        "the seeded catalog row must appear in the list"
    );

    // Assert that each movie has required fields
    for m in &list.movies {
        assert!(!m.filename.is_empty());
        assert!(!m.title.is_empty());
        assert!(m.percent >= 0.0 && m.percent <= 100.0);
    }

    // Teardown: leave no phantom catalog row behind.
    media_server_api::test_support::remove_seeded_media_row(&t.pool, &seeded).await;
}

#[tokio::test]
async fn test_movie_details_endpoint() {
    let t = setup_test_app().await;
    let seeded = seed_real_movie(&t.pool, &t.media_roots).await;
    let app = t.app;

    // Query details for the seeded real movie (encoding spaces for URI)
    let encoded_filename = seeded.replace(' ', "%20");
    let req_details = Request::builder()
        .uri(format!("/api/movie/{}", encoded_filename))
        .body(Body::empty())
        .unwrap();

    let res_details = app.clone().oneshot(req_details).await.unwrap();
    assert_eq!(res_details.status(), StatusCode::OK);

    let bytes_details = res_details.into_body().collect().await.unwrap().to_bytes();
    let details: MovieDetailsResponse = serde_json::from_slice(&bytes_details)
        .expect("Response does not conform to MovieDetailsResponse schema");

    assert_eq!(details.movie.filename, seeded);
    assert!(!details.movie.title.is_empty());
    assert!(
        details.specs.container.is_some(),
        "the real media file must be probed, so the container is known"
    );
    // Assert synchronized TechnicalSpecs fields
    assert!(
        details.specs.resolution_badge.is_some(),
        "resolution_badge must be populated"
    );
    assert!(
        !details.specs.subtitles.is_empty(),
        "subtitles list must be populated"
    );

    // Query non-existent movie -> expect 404
    let req_not_found = Request::builder()
        .uri("/api/movie/definitely_not_a_real_movie_9999.mp4")
        .body(Body::empty())
        .unwrap();

    let res_not_found = app.oneshot(req_not_found).await.unwrap();
    assert_eq!(res_not_found.status(), StatusCode::NOT_FOUND);

    // Teardown: leave no phantom catalog row behind.
    media_server_api::test_support::remove_seeded_media_row(&t.pool, &seeded).await;
}

#[tokio::test]
async fn test_media_info_quality_ladder_contract() {
    let t = setup_test_app().await;
    let seeded = seed_real_movie(&t.pool, &t.media_roots).await;
    let app = t.app;

    let encoded_filename = seeded.replace(' ', "%20");
    let req = Request::builder()
        .uri(format!("/api/media-info/{}", encoded_filename))
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes)
        .expect("Response must be valid JSON matching MediaInfoResponse");

    // Contract shape asserts
    assert!(json["container"].is_string());
    assert!(json["duration"].is_number());
    assert!(json["direct_play"].is_boolean());
    assert!(json["needs_transcode"].is_boolean());

    // Quality ladder contract assert
    let ladder = json["quality_ladder"]
        .as_array()
        .expect("quality_ladder must be an array");
    assert!(
        !ladder.is_empty(),
        "quality_ladder must have at least Direct Play option"
    );

    for opt in ladder {
        assert!(opt["label"].is_string());
        assert!(opt["quality"].is_string());
        assert!(opt["height"].is_number());
        assert!(opt["width"].is_number());
        assert!(opt["bitrate"].is_number());
        assert!(opt["is_direct"].is_boolean());
        assert!(opt["is_ready"].is_boolean());
    }

    // Teardown
    media_server_api::test_support::remove_seeded_media_row(&t.pool, &seeded).await;
}
