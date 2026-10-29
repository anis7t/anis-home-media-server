use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    create_app, db, models::progress::ProgressResponse, services::system_service::SystemService,
};
use tower::ServiceExt;

async fn setup_test_app() -> (axum::Router, sqlx::PgPool) {
    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();
    let app = create_app(
        pool.clone(),
        system_service,
        config.media_roots,
        config.cache_dir,
    );
    (app, pool)
}

#[tokio::test]
async fn test_progress_full_lifecycle() {
    let (app, pool) = setup_test_app().await;

    let test_filename = "Rust_Test_Progress_Movie_2026.mp4";
    let test_device_a = "rust_test_device_phone";
    let test_device_b = "rust_test_device_tv";

    // Clean up test rows before starting
    let _ = sqlx::query("DELETE FROM progress WHERE filename = $1")
        .bind(test_filename)
        .execute(&pool)
        .await;
    let _ = sqlx::query("DELETE FROM device_watch_history WHERE filename = $1")
        .bind(test_filename)
        .execute(&pool)
        .await;

    // 1. Initial GET on non-existent progress returns 0.0 position and 0.0 duration
    let req_init = Request::builder()
        .uri(format!("/api/progress?filename={}", test_filename))
        .header("x-device-id", test_device_a)
        .body(Body::empty())
        .unwrap();

    let res_init = app.clone().oneshot(req_init).await.unwrap();
    assert_eq!(res_init.status(), StatusCode::OK);
    let bytes_init = res_init.into_body().collect().await.unwrap().to_bytes();
    let prog_init: ProgressResponse = serde_json::from_slice(&bytes_init).unwrap();
    assert_eq!(prog_init.position, 0.0);
    assert_eq!(prog_init.duration, 0.0);

    // 2. POST progress for device A: position 120.5, duration 3600.0
    let payload = serde_json::json!({
        "filename": test_filename,
        "position": 120.5,
        "duration": 3600.0
    });
    let req_post = Request::builder()
        .method("POST")
        .uri("/api/progress")
        .header("content-type", "application/json")
        .header("x-device-id", test_device_a)
        .body(Body::from(payload.to_string()))
        .unwrap();

    let res_post = app.clone().oneshot(req_post).await.unwrap();
    assert_eq!(res_post.status(), StatusCode::OK);
    let bytes_post = res_post.into_body().collect().await.unwrap().to_bytes();
    let json_post: serde_json::Value = serde_json::from_slice(&bytes_post).unwrap();
    assert_eq!(json_post["success"], true);

    // 3. GET progress for device A returns updated values
    let req_get_a = Request::builder()
        .uri(format!("/api/progress?filename={}", test_filename))
        .header("x-device-id", test_device_a)
        .body(Body::empty())
        .unwrap();

    let res_get_a = app.clone().oneshot(req_get_a).await.unwrap();
    assert_eq!(res_get_a.status(), StatusCode::OK);
    let bytes_get_a = res_get_a.into_body().collect().await.unwrap().to_bytes();
    let prog_a: ProgressResponse = serde_json::from_slice(&bytes_get_a).unwrap();
    assert_eq!(prog_a.position, 120.5);
    assert_eq!(prog_a.duration, 3600.0);

    // 4. Multi-device isolation: GET progress for device B returns 0.0 (private device watch history)
    let req_get_b = Request::builder()
        .uri(format!("/api/progress?filename={}", test_filename))
        .header("x-device-id", test_device_b)
        .body(Body::empty())
        .unwrap();

    let res_get_b = app.clone().oneshot(req_get_b).await.unwrap();
    assert_eq!(res_get_b.status(), StatusCode::OK);
    let bytes_get_b = res_get_b.into_body().collect().await.unwrap().to_bytes();
    let prog_b: ProgressResponse = serde_json::from_slice(&bytes_get_b).unwrap();
    assert_eq!(prog_b.position, 0.0);

    // 5. Clamping test: POST progress with position exceeding duration clamps to duration
    let payload_clamp = serde_json::json!({
        "filename": test_filename,
        "position": 5000.0,
        "duration": 3600.0
    });
    let req_clamp = Request::builder()
        .method("POST")
        .uri("/api/progress")
        .header("content-type", "application/json")
        .header("x-device-id", test_device_a)
        .body(Body::from(payload_clamp.to_string()))
        .unwrap();

    let res_clamp = app.clone().oneshot(req_clamp).await.unwrap();
    assert_eq!(res_clamp.status(), StatusCode::OK);

    let req_get_clamped = Request::builder()
        .uri(format!("/api/progress?filename={}", test_filename))
        .header("x-device-id", test_device_a)
        .body(Body::empty())
        .unwrap();

    let res_get_clamped = app.clone().oneshot(req_get_clamped).await.unwrap();
    let bytes_clamped = res_get_clamped
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    let prog_clamped: ProgressResponse = serde_json::from_slice(&bytes_clamped).unwrap();
    assert_eq!(prog_clamped.position, 3600.0);
    assert_eq!(prog_clamped.duration, 3600.0);

    // 6. Direct PostgreSQL verification of 'completed' calculation
    let completed_row: (i32,) = sqlx::query_as(
        "SELECT completed::integer FROM device_watch_history WHERE device_id = $1 AND filename = $2",
    )
    .bind(test_device_a)
    .bind(test_filename)
    .fetch_one(&pool)
    .await
    .unwrap();

    assert_eq!(
        completed_row.0, 1,
        "Expected completed == 1 when position >= 90% duration"
    );

    // 7. Error handling: GET without filename returns 400
    let req_bad_get = Request::builder()
        .uri("/api/progress")
        .body(Body::empty())
        .unwrap();
    let res_bad_get = app.clone().oneshot(req_bad_get).await.unwrap();
    assert_eq!(res_bad_get.status(), StatusCode::BAD_REQUEST);

    // 8. Error handling: POST with empty filename returns 400
    let bad_payload = serde_json::json!({
        "filename": "",
        "position": 10.0,
        "duration": 100.0
    });
    let req_bad_post = Request::builder()
        .method("POST")
        .uri("/api/progress")
        .header("content-type", "application/json")
        .body(Body::from(bad_payload.to_string()))
        .unwrap();
    let res_bad_post = app.oneshot(req_bad_post).await.unwrap();
    assert_eq!(res_bad_post.status(), StatusCode::BAD_REQUEST);

    // Clean up test rows after completion
    let _ = sqlx::query("DELETE FROM progress WHERE filename = $1")
        .bind(test_filename)
        .execute(&pool)
        .await;
    let _ = sqlx::query("DELETE FROM device_watch_history WHERE filename = $1")
        .bind(test_filename)
        .execute(&pool)
        .await;
}
