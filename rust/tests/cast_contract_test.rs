//! Phase C4a: the four `/api/cast/*` contracts.
//!
//! These cover validation and the response envelope only. The parts that
//! actually touch a TV - discovery, load, transport state - are verified
//! against the live DU7000, because the metadata that enables its own seek
//! buttons only manifests there.

use axum::{
    body::Body,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{create_app, services::system_service::SystemService};
use serde_json::{json, Value};
use tower::ServiceExt;

async fn app() -> axum::Router {
    let config = media_server_api::test_support::test_config().await;
    let pool = media_server_api::db::create_test_pool(&config.database_url)
        .await
        .expect("pool");
    create_app(
        pool,
        SystemService::new(),
        config.media_roots,
        config.cache_dir,
    )
}

async fn call(app: &axum::Router, method: Method, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
    let payload = body.map(|b| b.to_string()).unwrap_or_default();
    let req = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(payload))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

#[tokio::test]
async fn status_without_a_device_id_is_a_400() {
    let app = app().await;
    let (status, body) = call(&app, Method::GET, "/api/cast/status", None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["ok"], false);
    assert_eq!(body["error"], "device_id is required");
}

#[tokio::test]
async fn status_for_an_unknown_device_says_so_rather_than_lying() {
    let app = app().await;
    let (status, body) = call(
        &app,
        Method::GET,
        "/api/cast/status?device_id=dlna:uuid:does-not-exist",
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["ok"], false);
    assert!(
        body["error"].as_str().unwrap().contains("Unknown device"),
        "a device a scan missed must be reported, not answered with a fabricated state"
    );
}

#[tokio::test]
async fn devices_answers_the_shape_the_picker_requires() {
    let app = app().await;
    let (status, body) = call(&app, Method::GET, "/api/cast/devices", None).await;
    assert_eq!(status, StatusCode::OK);
    // `ok` is load-bearing: the web picker treats its absence as a failure.
    assert_eq!(body["ok"], true);
    assert!(body["devices"].is_array());
    assert!(body["scanning"].is_boolean());
    assert!(body["errors"].is_object());
    assert!(body["scanned_at"].is_number());
}

#[tokio::test]
async fn play_requires_both_device_and_filename() {
    let app = app().await;
    for payload in [
        json!({}),
        json!({ "device_id": "dlna:x" }),
        json!({ "filename": "a.mkv" }),
        json!({ "device_id": "  ", "filename": "a.mkv" }),
    ] {
        let label = payload.to_string();
        let (status, body) = call(&app, Method::POST, "/api/cast/play", Some(payload)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{}", label);
        assert_eq!(body["error"], "device_id and filename are required");
    }
}

#[tokio::test]
async fn play_resolves_the_device_before_it_touches_the_path() {
    // The ordering is deliberate and matches Flask: an unknown device
    // short-circuits before any filename is looked at. It also means this
    // cannot be used to probe whether an arbitrary path exists, which is the
    // property we want from a public endpoint.
    let app = app().await;
    let (status, body) = call(
        &app,
        Method::POST,
        "/api/cast/play",
        Some(json!({ "device_id": "dlna:x", "filename": "../../windows/system32/config/sam" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "Unknown device - rescan and try again.");

    // The traversal defence itself lives in PathResolver, which refuses any
    // `..` component outright and is covered by its own tests.
    let roots = vec![std::path::PathBuf::from("E:\\MediaServer")];
    assert!(
        media_server_api::services::path_resolver::PathResolver::resolve_media_path(
            "../../windows/system32/config/sam",
            &roots
        )
        .is_err(),
        "a traversal name must never resolve"
    );
}

#[tokio::test]
async fn control_rejects_an_unknown_action_and_lists_the_real_ones() {
    let app = app().await;
    let (status, body) = call(
        &app,
        Method::POST,
        "/api/cast/control",
        Some(json!({ "device_id": "dlna:x", "action": "selfdestruct" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let message = body["error"].as_str().unwrap();
    assert!(message.starts_with("action must be one of"), "{}", message);
    for a in ["pause", "play", "seek", "stop", "subtitle", "volume"] {
        assert!(message.contains(a), "{} missing from {}", a, message);
    }
}

#[tokio::test]
async fn control_requires_a_device_id() {
    let app = app().await;
    let (status, body) = call(
        &app,
        Method::POST,
        "/api/cast/control",
        Some(json!({ "action": "play" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "device_id is required");
}

#[tokio::test]
async fn numeric_actions_reject_a_non_numeric_value() {
    let app = app().await;
    for action in ["seek", "volume"] {
        let (status, body) = call(
            &app,
            Method::POST,
            "/api/cast/control",
            Some(json!({ "device_id": "dlna:x", "action": action, "value": "abc" })),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{}", action);
        assert_eq!(body["error"], format!("{} needs a numeric value", action));
    }
}

#[tokio::test]
async fn volume_is_bounded_to_zero_through_one_hundred() {
    let app = app().await;
    for bad in [-1, 101, 1000] {
        let (status, body) = call(
            &app,
            Method::POST,
            "/api/cast/control",
            Some(json!({ "device_id": "dlna:x", "action": "volume", "value": bad })),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "volume={}", bad);
        assert_eq!(body["error"], "volume must be between 0 and 100");
    }
    // The boundaries themselves are valid, so they must get past validation
    // and fail as an unknown device instead. Both outcomes are 400, so the
    // error text - not the status - is what distinguishes them.
    for good in [0, 100] {
        let (_, body) = call(
            &app,
            Method::POST,
            "/api/cast/control",
            Some(json!({ "device_id": "dlna:x", "action": "volume", "value": good })),
        )
        .await;
        assert!(
            body["error"].as_str().unwrap_or("").contains("Unknown device"),
            "volume={} should have passed validation: {}",
            good,
            body
        );
    }
}

#[tokio::test]
async fn subtitle_offset_is_the_one_numeric_action_that_defaults() {
    let app = app().await;
    let (status, body) = call(
        &app,
        Method::POST,
        "/api/cast/control",
        Some(json!({ "device_id": "dlna:x", "action": "subtitle_offset" })),
    )
    .await;
    // It defaults to 0, so it gets past validation and fails as unknown device.
    assert!(body["error"].as_str().unwrap_or("").contains("Unknown device"), "{}", body);
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn transport_actions_carry_no_value_and_must_not_require_one() {
    // Caught by casting to the live DU7000: pause and stop were answered
    // "pause needs a numeric value" and could not be issued at all. Only
    // seek, volume and subtitle_offset take a number.
    let app = app().await;
    for action in ["play", "pause", "stop"] {
        let (status, body) = call(
            &app,
            Method::POST,
            "/api/cast/control",
            Some(json!({ "device_id": "dlna:x", "action": action })),
        )
        .await;
        assert_ne!(
            body["error"].as_str().unwrap_or(""),
            format!("{} needs a numeric value", action),
            "{} must not demand a value",
            action
        );
        assert_eq!(status, StatusCode::BAD_REQUEST, "{}", action);
        assert!(
            body["error"].as_str().unwrap_or("").contains("Unknown device"),
            "{} should have passed validation and reached the device: {}",
            action,
            body
        );
    }
}

#[tokio::test]
async fn cast_endpoints_are_no_longer_proxied() {
    let app = app().await;
    let calls = [
        (Method::GET, "/api/cast/devices", None),
        (Method::GET, "/api/cast/status?device_id=dlna:x", None),
        (Method::POST, "/api/cast/play", Some(json!({ "device_id": "d", "filename": "a.mkv" }))),
        (Method::POST, "/api/cast/control", Some(json!({ "device_id": "d", "action": "play" }))),
    ];
    for (method, uri, body) in calls {
        let (status, _) = call(&app, method, uri, body).await;
        assert_ne!(
            status,
            StatusCode::NOT_FOUND,
            "{} 404s: it is not registered at all, so it cannot be proxied either",
            uri
        );
    }
}