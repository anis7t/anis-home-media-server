use axum::{
    body::Body,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    create_app, db,
    models::transcode::TranscodeStatusResponse,
    services::{hls_service::HlsService, system_service::SystemService},
};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use tower::ServiceExt;

static TEST_COUNTER: AtomicUsize = AtomicUsize::new(200);

struct TestHlsHarness {
    app: axum::Router,
    media_dir: PathBuf,
    cache_dir: PathBuf,
}

impl Drop for TestHlsHarness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.media_dir);
        let _ = fs::remove_dir_all(&self.cache_dir);
    }
}

async fn setup_hls_test() -> TestHlsHarness {
    let count = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let media_dir = std::env::temp_dir().join(format!("rust_hls_media_{}_{}_{}", std::process::id(), now, count));
    let cache_dir = std::env::temp_dir().join(format!("rust_hls_cache_{}_{}_{}", std::process::id(), now, count));
    fs::create_dir_all(&media_dir).expect("Failed to create media directory");
    fs::create_dir_all(&cache_dir).expect("Failed to create cache directory");

    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();

    let roots = vec![media_dir.clone()];
    let app = create_app(pool, system_service, roots, cache_dir.clone());

    TestHlsHarness {
        app,
        media_dir,
        cache_dir,
    }
}

#[test]
fn test_honest_target_duration_adjustment() {
    let raw_manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.800000,\nsegment_000000.ts\n#EXTINF:3.950000,\nsegment_000001.ts\n";
    let honest = HlsService::honest_target_duration(raw_manifest);

    // 4.800000 ceil is 5, so TARGETDURATION must be raised from 4 to 5
    assert!(honest.contains("#EXT-X-TARGETDURATION:5"));
    assert!(!honest.contains("#EXT-X-TARGETDURATION:4"));

    // If already greater than or equal to ceil, it must not be lowered
    let already_safe = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXTINF:4.800000,\nsegment_000000.ts\n";
    let safe_honest = HlsService::honest_target_duration(already_safe);
    assert!(safe_honest.contains("#EXT-X-TARGETDURATION:6"));

    // If missing entirely, must be inserted
    let missing_decl = "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:3.500000,\nsegment_000000.ts\n";
    let inserted = HlsService::honest_target_duration(missing_decl);
    assert!(inserted.contains("#EXT-X-TARGETDURATION:4"));
}

#[test]
fn test_is_valid_segment_name() {
    assert!(HlsService::is_valid_segment_name("init.mp4"));
    assert!(HlsService::is_valid_segment_name("init_chunk_0.mp4"));
    assert!(HlsService::is_valid_segment_name("init_chunk_12.mp4"));
    assert!(HlsService::is_valid_segment_name("segment_000000.ts"));
    assert!(HlsService::is_valid_segment_name("segment_000015.m4s"));
    assert!(HlsService::is_valid_segment_name("segment_999999.ts"));

    assert!(!HlsService::is_valid_segment_name("../segment_000000.ts"));
    assert!(!HlsService::is_valid_segment_name("init_chunk_abc.mp4"));
    assert!(!HlsService::is_valid_segment_name("segment_1.ts"));
    assert!(!HlsService::is_valid_segment_name("segment_00000.ts"));
    assert!(!HlsService::is_valid_segment_name("segment_0000000.ts"));
    assert!(!HlsService::is_valid_segment_name("playlist.m3u8"));
    assert!(!HlsService::is_valid_segment_name("segment_000000.mp4"));
    assert!(!HlsService::is_valid_segment_name("foo.txt"));
}

#[tokio::test]
async fn test_hls_playlist_delivery_200_and_cors() {
    let harness = setup_hls_test().await;

    // Create a dummy video file
    let video_path = harness.media_dir.join("Inception.mkv");
    fs::write(&video_path, b"dummy mkv video content").unwrap();

    // Create candidate HLS cache dir
    let hls_dir = HlsService::find_hls_dir(&video_path, &[harness.media_dir.clone()], &harness.cache_dir);
    fs::create_dir_all(&hls_dir).unwrap();

    let playlist_content = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.500000,\nsegment_000000.ts\n#EXT-X-ENDLIST\n";
    fs::write(hls_dir.join("playlist.m3u8"), playlist_content).unwrap();

    let req = Request::builder()
        .method(Method::GET)
        .uri("/hls/Inception.mkv/playlist.m3u8")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let content_type = res.headers().get(header::CONTENT_TYPE).unwrap().to_str().unwrap();
    assert_eq!(content_type, "application/vnd.apple.mpegurl");

    let cache_control = res.headers().get(header::CACHE_CONTROL).unwrap().to_str().unwrap();
    assert_eq!(cache_control, "no-cache, max-age=0");

    let cors_origin = res.headers().get("access-control-allow-origin").unwrap().to_str().unwrap();
    assert_eq!(cors_origin, "*");

    let body_bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body_str = String::from_utf8_lossy(&body_bytes);
    // Honest target duration ceiling check (4.5s -> 5s)
    assert!(body_str.contains("#EXT-X-TARGETDURATION:5"));
    assert!(body_str.contains("segment_000000.ts"));
    assert!(body_str.contains("#EXT-X-ENDLIST"));
}

#[tokio::test]
async fn test_hls_playlist_in_flight_503_retry() {
    let harness = setup_hls_test().await;

    let video_path = harness.media_dir.join("Avatar.mkv");
    fs::write(&video_path, b"dummy avatar mkv").unwrap();

    // No playlist exists yet
    let req = Request::builder()
        .method(Method::GET)
        .uri("/hls/Avatar.mkv/playlist.m3u8")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);

    let retry_after = res.headers().get(header::RETRY_AFTER).unwrap().to_str().unwrap();
    assert_eq!(retry_after, "1");

    let cache_control = res.headers().get(header::CACHE_CONTROL).unwrap().to_str().unwrap();
    assert_eq!(cache_control, "no-cache, no-store, must-revalidate");

    let body_bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body_str = String::from_utf8_lossy(&body_bytes);
    assert!(body_str.starts_with("#EXTM3U"));
}

#[tokio::test]
async fn test_hls_segment_delivery_ts_and_range() {
    let harness = setup_hls_test().await;

    let video_path = harness.media_dir.join("Gladiator.mkv");
    fs::write(&video_path, b"gladiator content").unwrap();

    let hls_dir = HlsService::find_hls_dir(&video_path, &[harness.media_dir.clone()], &harness.cache_dir);
    fs::create_dir_all(&hls_dir).unwrap();

    let segment_bytes = vec![0x47u8; 1880]; // 10 TS packets
    fs::write(hls_dir.join("segment_000000.ts"), &segment_bytes).unwrap();

    // 1. Full GET
    let req = Request::builder()
        .method(Method::GET)
        .uri("/hls/Gladiator.mkv/segment_000000.ts")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let content_type = res.headers().get(header::CONTENT_TYPE).unwrap().to_str().unwrap();
    assert_eq!(content_type, "video/mp2t");

    let cache_control = res.headers().get(header::CACHE_CONTROL).unwrap().to_str().unwrap();
    assert_eq!(cache_control, "public, max-age=3600");

    let body_bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(body_bytes.len(), 1880);

    // 2. Partial Content (Range request)
    let range_req = Request::builder()
        .method(Method::GET)
        .uri("/hls/Gladiator.mkv/segment_000000.ts")
        .header(header::RANGE, "bytes=0-187")
        .body(Body::empty())
        .unwrap();

    let range_res = harness.app.clone().oneshot(range_req).await.unwrap();
    assert_eq!(range_res.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(range_res.headers().get(header::CONTENT_RANGE).unwrap(), "bytes 0-187/1880");
    let range_bytes = range_res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(range_bytes.len(), 188);
}

#[tokio::test]
async fn test_hls_segment_delivery_m4s_and_init() {
    let harness = setup_hls_test().await;

    let video_path = harness.media_dir.join("Dune.mkv");
    fs::write(&video_path, b"dune video").unwrap();

    let hls_dir = HlsService::find_hls_dir(&video_path, &[harness.media_dir.clone()], &harness.cache_dir);
    fs::create_dir_all(&hls_dir).unwrap();

    fs::write(hls_dir.join("init.mp4"), b"ftypisom").unwrap();
    fs::write(hls_dir.join("segment_000001.m4s"), b"moofmdat").unwrap();

    // Check init.mp4
    let req_init = Request::builder()
        .method(Method::GET)
        .uri("/hls/Dune.mkv/init.mp4")
        .body(Body::empty())
        .unwrap();

    let res_init = harness.app.clone().oneshot(req_init).await.unwrap();
    assert_eq!(res_init.status(), StatusCode::OK);
    assert_eq!(res_init.headers().get(header::CONTENT_TYPE).unwrap(), "video/mp4");

    // Check segment_000001.m4s
    let req_m4s = Request::builder()
        .method(Method::GET)
        .uri("/hls/Dune.mkv/segment_000001.m4s")
        .body(Body::empty())
        .unwrap();

    let res_m4s = harness.app.clone().oneshot(req_m4s).await.unwrap();
    assert_eq!(res_m4s.status(), StatusCode::OK);
    assert_eq!(res_m4s.headers().get(header::CONTENT_TYPE).unwrap(), "video/iso.segment");
}

#[tokio::test]
async fn test_hls_quality_tier_subpath_delivery() {
    let harness = setup_hls_test().await;

    let video_path = harness.media_dir.join("Matrix.mkv");
    fs::write(&video_path, b"matrix video content").unwrap();

    let base_hls_dir = HlsService::find_hls_dir(&video_path, &[harness.media_dir.clone()], &harness.cache_dir);
    let quality_720_dir = base_hls_dir.join("720p");
    fs::create_dir_all(&quality_720_dir).unwrap();

    // Write 720p fMP4 playlist and segments
    let pl_720 = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"init_chunk_0.mp4\"\n#EXTINF:4.000000,\nsegment_000000.m4s\n#EXT-X-ENDLIST\n";
    fs::write(quality_720_dir.join("playlist.m3u8"), pl_720).unwrap();
    fs::write(quality_720_dir.join("init_chunk_0.mp4"), b"init_720_bytes").unwrap();
    fs::write(quality_720_dir.join("segment_000000.m4s"), b"m4s_720_bytes").unwrap();

    // 1. GET /hls/Matrix.mkv/720p/playlist.m3u8
    let req_pl = Request::builder()
        .method(Method::GET)
        .uri("/hls/Matrix.mkv/720p/playlist.m3u8")
        .body(Body::empty())
        .unwrap();

    let res_pl = harness.app.clone().oneshot(req_pl).await.unwrap();
    assert_eq!(res_pl.status(), StatusCode::OK);
    assert_eq!(res_pl.headers().get(header::CONTENT_TYPE).unwrap(), "application/vnd.apple.mpegurl");

    let pl_bytes = res_pl.into_body().collect().await.unwrap().to_bytes();
    let pl_str = String::from_utf8_lossy(&pl_bytes);
    assert!(pl_str.contains("#EXT-X-VERSION:7"));
    assert!(pl_str.contains("#EXT-X-MAP:URI=\"init_chunk_0.mp4\""));
    assert!(pl_str.contains("segment_000000.m4s"));

    // 2. GET /hls/Matrix.mkv/720p/init_chunk_0.mp4
    let req_init = Request::builder()
        .method(Method::GET)
        .uri("/hls/Matrix.mkv/720p/init_chunk_0.mp4")
        .body(Body::empty())
        .unwrap();

    let res_init = harness.app.clone().oneshot(req_init).await.unwrap();
    assert_eq!(res_init.status(), StatusCode::OK);
    assert_eq!(res_init.headers().get(header::CONTENT_TYPE).unwrap(), "video/mp4");

    // 3. GET /hls/Matrix.mkv/720p/segment_000000.m4s
    let req_seg = Request::builder()
        .method(Method::GET)
        .uri("/hls/Matrix.mkv/720p/segment_000000.m4s")
        .body(Body::empty())
        .unwrap();

    let res_seg = harness.app.clone().oneshot(req_seg).await.unwrap();
    assert_eq!(res_seg.status(), StatusCode::OK);
    assert_eq!(res_seg.headers().get(header::CONTENT_TYPE).unwrap(), "video/iso.segment");
}

#[tokio::test]
async fn test_hls_segment_traversal_and_invalid_names_404() {
    let harness = setup_hls_test().await;

    let video_path = harness.media_dir.join("Movie.mkv");
    fs::write(&video_path, b"test").unwrap();

    // Invalid format name
    let req1 = Request::builder()
        .method(Method::GET)
        .uri("/hls/Movie.mkv/invalid_segment.ts")
        .body(Body::empty())
        .unwrap();

    let res1 = harness.app.clone().oneshot(req1).await.unwrap();
    assert_eq!(res1.status(), StatusCode::NOT_FOUND);

    // Non-existent valid name
    let req2 = Request::builder()
        .method(Method::GET)
        .uri("/hls/Movie.mkv/segment_000999.ts")
        .body(Body::empty())
        .unwrap();

    let res2 = harness.app.clone().oneshot(req2).await.unwrap();
    assert_eq!(res2.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_transcode_cached_mp4_delivery() {
    let harness = setup_hls_test().await;

    let video_path = harness.media_dir.join("Interstellar.mkv");
    fs::write(&video_path, b"interstellar source").unwrap();

    // Cache destination
    let cached = HlsService::get_transcode_cache_path(&video_path, "direct", &harness.cache_dir);
    fs::create_dir_all(cached.parent().unwrap()).unwrap();
    fs::write(&cached, vec![0u8; 10000]).unwrap();

    let req = Request::builder()
        .method(Method::GET)
        .uri("/transcode/Interstellar.mkv")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers().get(header::CONTENT_TYPE).unwrap(), "video/mp4");
    assert_eq!(res.headers().get(header::CACHE_CONTROL).unwrap(), "public, max-age=3600");
    assert_eq!(res.headers().get("access-control-allow-origin").unwrap(), "*");

    // Status endpoint should report complete
    let status_req = Request::builder()
        .method(Method::GET)
        .uri("/api/transcode-status/Interstellar.mkv")
        .body(Body::empty())
        .unwrap();

    let status_res = harness.app.clone().oneshot(status_req).await.unwrap();
    assert_eq!(status_res.status(), StatusCode::OK);
    let bytes = status_res.into_body().collect().await.unwrap().to_bytes();
    let status_json: TranscodeStatusResponse = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(status_json.status, "complete");
    assert!(status_json.is_complete);
}

#[tokio::test]
async fn test_transcode_uncached_returns_503_and_idle_status() {
    let harness = setup_hls_test().await;

    let video_path = harness.media_dir.join("UncachedMovie.mkv");
    fs::write(&video_path, b"uncached source").unwrap();

    // GET /transcode should return 503 retry
    let req = Request::builder()
        .method(Method::GET)
        .uri("/transcode/UncachedMovie.mkv")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(res.headers().get(header::RETRY_AFTER).unwrap(), "2");

    // Status endpoint should report idle
    let status_req = Request::builder()
        .method(Method::GET)
        .uri("/api/transcode-status/UncachedMovie.mkv")
        .body(Body::empty())
        .unwrap();

    let status_res = harness.app.clone().oneshot(status_req).await.unwrap();
    assert_eq!(status_res.status(), StatusCode::OK);
    let bytes = status_res.into_body().collect().await.unwrap().to_bytes();
    let status_json: TranscodeStatusResponse = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(status_json.status, "idle");
    assert!(!status_json.is_complete);
}

#[tokio::test]
async fn test_hls_and_transcode_options_cors() {
    let harness = setup_hls_test().await;

    let hls_opt = Request::builder()
        .method(Method::OPTIONS)
        .uri("/hls/AnyMovie.mkv/playlist.m3u8")
        .body(Body::empty())
        .unwrap();
    let res1 = harness.app.clone().oneshot(hls_opt).await.unwrap();
    assert_eq!(res1.status(), StatusCode::OK);
    assert_eq!(res1.headers().get("access-control-allow-origin").unwrap(), "*");
    let allow_methods = res1.headers().get("access-control-allow-methods").unwrap().to_str().unwrap();
    assert!(allow_methods == "*" || allow_methods.contains("GET"));

    let tc_opt = Request::builder()
        .method(Method::OPTIONS)
        .uri("/transcode/AnyMovie.mkv")
        .body(Body::empty())
        .unwrap();

    let res2 = harness.app.clone().oneshot(tc_opt).await.unwrap();
    assert_eq!(res2.status(), StatusCode::OK);
    assert_eq!(res2.headers().get("access-control-allow-origin").unwrap(), "*");
}

#[tokio::test]
async fn test_hls_master_playlist_multi_tier_delivery() {
    let harness = setup_hls_test().await;

    let video_path = harness.media_dir.join("Inception.mkv");
    fs::write(&video_path, b"inception media data").unwrap();

    let base_hls_dir = HlsService::find_hls_dir(&video_path, &[harness.media_dir.clone()], &harness.cache_dir);
    let q1080 = base_hls_dir.join("1080p");
    let q720 = base_hls_dir.join("720p");
    let q480 = base_hls_dir.join("480p");
    fs::create_dir_all(&q1080).unwrap();
    fs::create_dir_all(&q720).unwrap();
    fs::create_dir_all(&q480).unwrap();

    // Write tier playlists
    let pl_1080 = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"init_chunk_0.mp4\"\n#EXTINF:4.000000,\nsegment_000000.m4s\n#EXT-X-ENDLIST\n";
    let pl_720 = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"init_chunk_0.mp4\"\n#EXTINF:4.000000,\nsegment_000000.m4s\n#EXT-X-ENDLIST\n";
    let pl_480 = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"init_chunk_0.mp4\"\n#EXTINF:4.000000,\nsegment_000000.m4s\n#EXT-X-ENDLIST\n";
    fs::write(q1080.join("playlist.m3u8"), pl_1080).unwrap();
    fs::write(q720.join("playlist.m3u8"), pl_720).unwrap();
    fs::write(q480.join("playlist.m3u8"), pl_480).unwrap();

    // 1. GET /hls/Inception.mkv/master.m3u8
    let req = Request::builder()
        .method(Method::GET)
        .uri("/hls/Inception.mkv/master.m3u8")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers().get(header::CONTENT_TYPE).unwrap(), "application/vnd.apple.mpegurl");

    let body = res.into_body().collect().await.unwrap().to_bytes();
    let body_str = String::from_utf8_lossy(&body);

    assert!(body_str.contains("#EXTM3U"));
    assert!(body_str.contains("#EXT-X-VERSION:7"));
    assert!(body_str.contains("#EXT-X-INDEPENDENT-SEGMENTS"));
    assert!(body_str.contains("RESOLUTION=1920x1080"));
    assert!(body_str.contains("1080p/playlist.m3u8"));
    assert!(body_str.contains("RESOLUTION=1280x720"));
    assert!(body_str.contains("720p/playlist.m3u8"));
    assert!(body_str.contains("RESOLUTION=854x480"));
    assert!(body_str.contains("480p/playlist.m3u8"));

    // 2. GET /hls/Inception.mkv/playlist.m3u8 without quality subpath should auto-serve master playlist
    let req2 = Request::builder()
        .method(Method::GET)
        .uri("/hls/Inception.mkv/playlist.m3u8")
        .body(Body::empty())
        .unwrap();

    let res2 = harness.app.clone().oneshot(req2).await.unwrap();
    assert_eq!(res2.status(), StatusCode::OK);
    let body2 = res2.into_body().collect().await.unwrap().to_bytes();
    let body2_str = String::from_utf8_lossy(&body2);
    assert!(body2_str.contains("#EXT-X-STREAM-INF"));
    assert!(body2_str.contains("1080p/playlist.m3u8"));
}

#[tokio::test]
async fn test_hls_master_playlist_in_flight_503() {
    let harness = setup_hls_test().await;

    let video_path = harness.media_dir.join("Dune.mkv");
    fs::write(&video_path, b"dune media data").unwrap();

    // No playlists exist yet
    let req = Request::builder()
        .method(Method::GET)
        .uri("/hls/Dune.mkv/master.m3u8")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(res.headers().get(header::RETRY_AFTER).unwrap(), "1");
}

#[test]
fn test_hls_service_detects_completed_tiered_transcode() {
    let temp_dir = std::env::temp_dir().join(format!("rust_tier_test_{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp_dir);
    fs::create_dir_all(&temp_dir).unwrap();

    assert!(!HlsService::is_hls_complete(&temp_dir));

    let q1080 = temp_dir.join("1080p");
    fs::create_dir_all(&q1080).unwrap();
    let pl_1080 = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MAP:URI=\"init_chunk_0.mp4\"\n#EXTINF:4.0,\nsegment_000000.m4s\n#EXT-X-ENDLIST\n";
    fs::write(q1080.join("playlist.m3u8"), pl_1080).unwrap();

    // is_hls_complete must detect #EXT-X-ENDLIST in nested quality tier
    assert!(HlsService::is_hls_complete(&temp_dir));

    let _ = fs::remove_dir_all(&temp_dir);
}
