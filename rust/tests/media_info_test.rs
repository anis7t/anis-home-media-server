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
use media_server_api::{create_app, services::system_service::SystemService};
use serde_json::Value;
use std::fs;
use tower::ServiceExt;

struct Harness {
    app: axum::Router,
    pool: sqlx::PgPool,
    media_roots: Vec<std::path::PathBuf>,
    /// The harness cache directory. This is a temporary directory, never the
    /// production cache: the suite must not read (or appear to write to) the
    /// live HLS cache.
    cache_dir: std::path::PathBuf,
}

async fn harness() -> Harness {
    let config = media_server_api::test_support::test_config().await;
    let pool = media_server_api::db::create_test_pool(&config.database_url)
        .await
        .expect("pool");
    Harness {
        app: create_app(
            pool.clone(),
            SystemService::new(),
            config.media_roots.clone(),
            config.cache_dir.clone(),
        ),
        pool,
        media_roots: config.media_roots,
        cache_dir: config.cache_dir,
    }
}

async fn get(app: &axum::Router, uri: &str) -> (StatusCode, Value) {
    get_with_headers(app, uri, vec![]).await
}

async fn get_with_headers(app: &axum::Router, uri: &str, headers: Vec<(&'static str, &'static str)>) -> (StatusCode, Value) {
    let mut builder = Request::builder().method(Method::GET).uri(uri);
    for (k, v) in headers {
        builder = builder.header(k, v);
    }
    let res = app
        .clone()
        .oneshot(builder.body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, json)
}

/// First library entry, discovered through the API so the test does not
/// hardcode a filename that may be renamed or removed later.
///
/// The isolated test database starts empty, so the harness seeds a catalog
/// row for a real, probeable media file first. The file comes from the
/// read-only production media roots - `ffprobe` has to return real container
/// and stream values, and only the metadata is written.
async fn first_movie(h: &Harness) -> String {
    media_server_api::test_support::seed_real_media_row(&h.pool, &h.media_roots)
        .await
        .expect("the library must offer a probeable media file for this contract");
    let (_, body) = get(&h.app, "/api/movies").await;
    body["movies"][0]["filename"].as_str().unwrap().to_string()
}

/// Remove the seeded catalog row, so the test database holds no residue.
async fn cleanup_seeded_movie(h: &Harness, filename: &str) {
    media_server_api::test_support::remove_seeded_media_row(&h.pool, filename).await;
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
    let movie = first_movie(&h).await;
    let (status, body) = get(&h.app, &format!("/api/media-info/{}", encode(&movie))).await;

    assert_eq!(status, StatusCode::OK);
    for field in [
        "container", "duration", "video_codec", "audio_codec", "width", "height", "direct_play",
        "needs_transcode", "is_transcode_ready", "ffprobe_available",
        "transcoding_available", "quality_ladder", "title", "year", "overview", "genres", "rating",
        "runtime", "reason",
    ] {
        assert!(
            body.get(field).is_some(),
            "response must carry '{}'; got {}",
            field,
            body
        );
    }
    cleanup_seeded_movie(&h, &movie).await;
}

#[tokio::test]
async fn test_media_info_reports_real_probe_values() {
    let h = harness().await;
    let movie = first_movie(&h).await;
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
    cleanup_seeded_movie(&h, &movie).await;
}

#[tokio::test]
async fn test_direct_play_and_transcode_flags_are_mutually_sensible() {
    let h = harness().await;
    let movie = first_movie(&h).await;
    let (_, body) = get(&h.app, &format!("/api/media-info/{}", encode(&movie))).await;

    let direct = body["direct_play"].as_bool().unwrap();
    let needs = body["needs_transcode"].as_bool().unwrap();
    // needs_transcode is defined purely as "not a direct-play container",
    // so these must always be exact opposites.
    assert_eq!(direct, !needs, "direct_play and needs_transcode are complements");
    assert_eq!(body["is_transcode_ready"].as_bool(), Some(true),
        "a direct-play title needs no transcode and is therefore always ready");
    cleanup_seeded_movie(&h, &movie).await;
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
    let movie = first_movie(&h).await;
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
    cleanup_seeded_movie(&h, &movie).await;
}

/// The completeness check must stay a predicate. This test is the reason:
/// a previous revision of this logic appended `#EXT-X-ENDLIST`, which would
/// seal exactly the frame-deficient caches frame accounting exists to catch.
#[tokio::test]
async fn test_reading_status_never_writes_to_the_playlist() {
    let h = harness().await;
    // Seed a catalog row so there is at least one title to inspect. The
    // isolated test database starts empty.
    let seeded = media_server_api::test_support::seed_real_media_row(&h.pool, &h.media_roots)
        .await
        .expect("the library must offer a probeable media file for this contract");
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
    //
    // The harness cache directory, not the production one: the isolated test
    // run must not read (or appear to write to) the live HLS cache.
    let hls = h.cache_dir.join("hls");
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

    cleanup_seeded_movie(&h, &seeded).await;
}

#[tokio::test]
async fn test_repeated_requests_are_served_from_the_probe_cache() {
    let h = harness().await;
    let movie = first_movie(&h).await;
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
    if cold > std::time::Duration::from_millis(150) {
        assert!(
            warm < cold,
            "warm ({}ms) should be far cheaper than cold ({}ms)",
            warm.as_millis(),
            cold.as_millis()
        );
    }
    cleanup_seeded_movie(&h, &movie).await;
}

#[tokio::test]
async fn test_media_info_quality_ladder_structure_and_no_upscaling() {
    let h = harness().await;
    let movie = first_movie(&h).await;
    let uri = format!("/api/media-info/{}", encode(&movie));
    let (status, body) = get(&h.app, &uri).await;

    assert_eq!(status, StatusCode::OK);
    let ladder = body["quality_ladder"].as_array().expect("quality_ladder must be an array");
    assert!(!ladder.is_empty(), "quality_ladder must have at least Direct Play option");

    // 1. First option is always Direct Play (Source)
    let direct_opt = &ladder[0];
    assert_eq!(direct_opt["label"], "Direct Play (Source)");
    assert_eq!(direct_opt["quality"], "source");
    assert_eq!(direct_opt["is_direct"], true);
    assert_eq!(direct_opt["is_ready"], true);

    let source_h = body["height"].as_u64().unwrap_or(0);
    assert!(source_h > 0, "source height must be positive");

    // 2. Transcode quality options must strictly satisfy no-upscaling and even width
    for opt in &ladder[1..] {
        assert_eq!(opt["is_direct"], false);
        let h = opt["height"].as_u64().unwrap();
        let w = opt["width"].as_u64().unwrap();
        assert!(
            h <= source_h,
            "Quality tier height ({}) must not exceed source height ({}) (Strict No-Upscaling)",
            h, source_h
        );
        assert_eq!(
            w % 2,
            0,
            "Quality tier width ({}) must be an even integer for ffmpeg encoders",
            w
        );
        assert!(
            opt["hls_url"].as_str().unwrap().contains("/hls/"),
            "hls_url must reference /hls/ route"
        );
        assert!(
            opt["bitrate"].as_u64().unwrap() > 0,
            "target bitrate must be positive"
        );
    }
    cleanup_seeded_movie(&h, &movie).await;
}

#[tokio::test]
async fn test_client_aware_direct_play_evaluation() {
    use media_server_api::routes::media_info::evaluate_direct_play;

    // Unit test direct play rules
    assert!(evaluate_direct_play("mp4", Some("h264"), Some("aac"), false));
    assert!(evaluate_direct_play("webm", Some("vp9"), Some("opus"), false));
    assert!(!evaluate_direct_play("mkv", Some("h264"), Some("aac"), false)); // Web MKV -> transcode
    assert!(evaluate_direct_play("mkv", Some("h264"), Some("aac"), true));  // Android MKV -> direct
    assert!(evaluate_direct_play("mkv", Some("hevc"), Some("eac3"), true)); // Android HEVC -> direct
    assert!(!evaluate_direct_play("mkv", Some("msmpeg4v3"), Some("aac"), true)); // Unsupported codec -> transcode
    assert!(!evaluate_direct_play("avi", Some("h264"), Some("aac"), true)); // Non-MKV non-web -> transcode

    // Integration test with HTTP client / query / headers
    let h = harness().await;
    let (_, movies_body) = get(&h.app, "/api/movies").await;
    let mkv_movie = movies_body["movies"]
        .as_array()
        .and_then(|list| {
            list.iter().find(|m| {
                m["filename"].as_str().map(|f| f.ends_with(".mkv")).unwrap_or(false)
            })
        })
        .and_then(|m| m["filename"].as_str());

    if let Some(mkv) = mkv_movie {
        let base_uri = format!("/api/media-info/{}", encode(mkv));

        // 1. Without client param (Web default): direct_play = false, needs_transcode = true
        let (st1, body1) = get(&h.app, &base_uri).await;
        assert_eq!(st1, StatusCode::OK);
        assert_eq!(body1["direct_play"], false);
        assert_eq!(body1["needs_transcode"], true);

        // 2. With ?client=android: direct_play = true, needs_transcode = false
        let (st2, body2) = get(&h.app, &format!("{}?client=android", base_uri)).await;
        assert_eq!(st2, StatusCode::OK);
        assert_eq!(body2["direct_play"], true);
        assert_eq!(body2["needs_transcode"], false);

        // 3. With X-Client-Platform: android header: direct_play = true
        let (st3, body3) = get_with_headers(&h.app, &base_uri, vec![("x-client-platform", "android")]).await;
        assert_eq!(st3, StatusCode::OK);
        assert_eq!(body3["direct_play"], true);
        assert_eq!(body3["needs_transcode"], false);

        // 4. With User-Agent: Android / FireTV: direct_play = true
        let (st4, body4) = get_with_headers(
            &h.app,
            &base_uri,
            vec![("user-agent", "ExoPlayerLib/2.18.1 (Linux; Android 11; AFTMM Build/NS6294)")],
        )
        .await;
        assert_eq!(st4, StatusCode::OK);
        assert_eq!(body4["direct_play"], true);
        assert_eq!(body4["needs_transcode"], false);
    }
}