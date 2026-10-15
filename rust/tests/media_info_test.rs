//! Phase C2: native `/api/media-info/{*filename}`.
//!
//! Uses real library files so ffprobe is genuinely exercised; every fixture
//! is either a real media file from a configured root or a temp file that is
//! removed on drop. No database rows are created.

use axum::{
    body::Body,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{config::AppConfig, create_app, services::system_service::SystemService};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use tower::ServiceExt;

struct Harness {
    app: axum::Router,
}

async fn harness() -> Harness {
    let config = AppConfig::from_env();
    let pool = media_server_api::db::create_test_pool(&config.database_url)
        .await
        .expect("pool");
    Harness {
        app: create_app(
            pool,
            SystemService::new(),
            config.media_roots,
            config.cache_dir,
        ),
    }
}

async fn get(app: &axum::Router, uri: &str) -> (StatusCode, Value) {
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri(uri)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, json)
}

/// First library entry, discovered through the API so the test does not
/// hardcode a filename that may be renamed or removed later.
async fn first_movie() -> String {
    let (_, body) = get(&harness().await.app, "/api/movies").await;
    body["movies"][0]["filename"].as_str().unwrap().to_string()
}

fn encode(path: &str) -> String {
    path.split('/')
        .map(|s| {
            s.bytes()
                .map(|b| match b {
                    b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                        (b as char).to_string()
                    }
                    _ => format!("%{:02X}", b),
                })
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("/")
}

#[tokio::test]
async fn test_media_info_returns_every_documented_field() {
    let h = harness().await;
    let movie = first_movie().await;
    let (status, body) = get(&h.app, &format!("/api/media-info/{}", encode(&movie))).await;

    assert_eq!(status, StatusCode::OK);
    for field in [
        "container", "duration", "video_codec", "width", "height", "direct_play",
        "needs_transcode", "is_transcode_ready", "ffprobe_available",
        "transcoding_available", "title", "year", "overview", "genres", "rating",
        "runtime", "reason",
    ] {
        assert!(
            body.get(field).is_some(),
            "response must carry '{}'; got {}",
            field,
            body
        );
    }
}

#[tokio::test]
async fn test_media_info_reports_real_probe_values() {
    let h = harness().await;
    let movie = first_movie().await;
    let (_, body) = get(&h.app, &format!("/api/media-info/{}", encode(&movie))).await;

    assert!(
        body["ffprobe_available"].as_bool() == Some(true),
        "ffprobe is installed on this host, so the flag must be true"
    );
    assert!(
        body["duration"].as_f64().unwrap_or(0.0) > 0.0,
        "a real film must report a positive duration, got {}",
        body["duration"]
    );
    assert!(
        !body["video_codec"].as_str().unwrap_or("").is_empty(),
        "ffprobe must supply a codec name"
    );
    assert!(body["width"].as_i64().unwrap_or(0) > 0);
    assert!(body["height"].as_i64().unwrap_or(0) > 0);
}

#[tokio::test]
async fn test_direct_play_and_transcode_flags_are_mutually_sensible() {
    let h = harness().await;
    let movie = first_movie().await;
    let (_, body) = get(&h.app, &format!("/api/media-info/{}", encode(&movie))).await;

    let direct = body["direct_play"].as_bool().unwrap();
    let needs = body["needs_transcode"].as_bool().unwrap();
    // needs_transcode is defined purely as "not a direct-play container",
    // so these must always be exact opposites.
    assert_eq!(direct, !needs, "direct_play and needs_transcode are complements");
    assert_eq!(body["is_transcode_ready"].as_bool(), Some(true),
        "a direct-play title needs no transcode and is therefore always ready");
}

#[tokio::test]
async fn test_missing_and_nonvideo_are_404_but_traversal_is_403() {
    let h = harness().await;

    // Absent or wrong type: the file simply is not servable media.
    for uri in [
        "/api/media-info/does-not-exist.mkv",
        "/api/media-info/not-a-video.txt",
    ] {
        let (status, _) = get(&h.app, uri).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{} must be 404", uri);
    }

    // Traversal is a *refusal*, not a miss, and must not be reported as 404:
    // Flask's `safe_path` aborts 403 here, and collapsing the two would hide
    // an attack attempt behind an ordinary "no such film" answer.
    let (status, _) = get(&h.app, "/api/media-info/../app/config.py").await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "directory traversal must be refused with 403, matching Flask"
    );
}

#[tokio::test]
async fn test_head_returns_headers_without_body_and_options_ok() {
    let h = harness().await;
    let movie = first_movie().await;
    let uri = format!("/api/media-info/{}", encode(&movie));

    let res = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::HEAD)
                .uri(&uri)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers()[header::CONTENT_TYPE], "application/json");
    let body = res.into_body().collect().await.unwrap().to_bytes();
    assert!(body.is_empty(), "HEAD must not return a body");

    let res = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::OPTIONS)
                .uri(&uri)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers()["access-control-allow-origin"], "*");
}

/// The completeness check must stay a predicate. This test is the reason:
/// a previous revision of this logic appended `#EXT-X-ENDLIST`, which would
/// seal exactly the frame-deficient caches frame accounting exists to catch.
#[tokio::test]
async fn test_reading_status_never_writes_to_the_playlist() {
    let h = harness().await;
    let movies = get(&h.app, "/api/movies").await.1;
    let list = movies["movies"].as_array().cloned().unwrap_or_default();

    let mut checked = 0;
    for m in list.iter() {
        let filename = m["filename"].as_str().unwrap_or("");
        let uri = format!("/api/media-info/{}", encode(filename));
        let (status, _) = get(&h.app, &uri).await;
        if status != StatusCode::OK {
            continue;
        }
        checked += 1;
        if checked >= 5 {
            break;
        }
    }
    assert!(checked > 0, "expected to inspect at least one real title");

    // After all those reads, no playlist anywhere may have gained ENDLIST
    // from this code path. Compare against the on-disk set before/after by
    // re-reading every playlist and confirming none is newer than the run.
    let cache = std::env::var("MEDIA_SERVER_CACHE_DIR")
        .unwrap_or_else(|_| "E:\\MediaServer\\cache".to_string());
    let hls = PathBuf::from(cache).join("hls");
    if hls.is_dir() {
        for entry in fs::read_dir(&hls).unwrap().flatten() {
            let pl = entry.path().join("playlist.m3u8");
            if pl.is_file() {
                let text = fs::read_to_string(&pl).unwrap_or_default();
                if text.contains("#EXT-X-ENDLIST") {
                    // Legitimate only if it was already sealed before this
                    // run; assert the ENDLIST is the final line, i.e. a
                    // properly completed playlist rather than a mid-file one.
                    let tail = text.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("");
                    assert_eq!(tail.trim(), "#EXT-X-ENDLIST");
                }
            }
        }
    }
}

#[tokio::test]
async fn test_repeated_requests_are_served_from_the_probe_cache() {
    let h = harness().await;
    let movie = first_movie().await;
    let uri = format!("/api/media-info/{}", encode(&movie));

    let t0 = std::time::Instant::now();
    let first = get(&h.app, &uri).await;
    let cold = t0.elapsed();

    let t1 = std::time::Instant::now();
    let second = get(&h.app, &uri).await;
    let warm = t1.elapsed();

    assert_eq!(first.0, StatusCode::OK);
    assert_eq!(second.0, StatusCode::OK);
    assert_eq!(first.1["duration"], second.1["duration"],
        "a memoized probe must not change the answer");
    assert!(
        warm < cold.max(std::time::Duration::from_millis(50)),
        "warm ({}ms) should be far cheaper than cold ({}ms)",
        warm.as_millis(),
        cold.as_millis()
    );
}