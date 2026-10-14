use axum::{
    body::Body,
    http::{header, Method, Request, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    config::AppConfig,
    create_app, db,
    models::subtitle::SubtitleListResponse,
    services::{subtitle_service::SubtitleService, system_service::SystemService},
};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use tower::ServiceExt;

static TEST_COUNTER: AtomicUsize = AtomicUsize::new(100);

struct TestSubtitleHarness {
    app: axum::Router,
    test_dir: PathBuf,
    cache_dir: PathBuf,
}

impl Drop for TestSubtitleHarness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.test_dir);
        let _ = fs::remove_dir_all(&self.cache_dir);
    }
}

async fn setup_subtitle_test() -> TestSubtitleHarness {
    let count = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let test_dir = std::env::temp_dir().join(format!("rust_sub_test_{}_{}_{}", std::process::id(), now, count));
    let cache_dir = std::env::temp_dir().join(format!("rust_sub_cache_{}_{}_{}", std::process::id(), now, count));
    fs::create_dir_all(&test_dir).expect("Failed to create test directory");
    fs::create_dir_all(&cache_dir).expect("Failed to create cache directory");

    let config = AppConfig::from_env();
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let system_service = SystemService::new();

    let roots = vec![test_dir.clone()];
    let app = create_app(pool, system_service, roots, cache_dir.clone());

    TestSubtitleHarness { app, test_dir, cache_dir }
}

#[test]
fn test_srt_to_vtt_conversion() {
    let srt = "1\r\n00:01:20,123 --> 00:01:24,456\r\nHello, world!\r\n\r\n2\r\n00:01:25,000 --> 00:01:28,000\r\nSecond subtitle.\r\n";
    let vtt = SubtitleService::srt_to_vtt(srt, 0.0);

    assert!(vtt.starts_with("WEBVTT\n"));
    assert!(vtt.contains("00:01:20.123 --> 00:01:24.456"));
    assert!(vtt.contains("00:01:25.000 --> 00:01:28.000"));
    assert!(vtt.contains("Hello, world!"));
    assert!(vtt.contains("Second subtitle."));
    // Sequence numbers should be stripped
    assert!(!vtt.contains("\n1\n") && !vtt.contains("\n2\n"));
}

#[test]
fn test_srt_to_vtt_offset_shift() {
    let srt = "1\n00:01:00,000 --> 00:01:05,000\nShift me forward.\n";
    let vtt = SubtitleService::srt_to_vtt(srt, 2.5);

    assert!(vtt.contains("00:01:02.500 --> 00:01:07.500"));

    let vtt_back = SubtitleService::srt_to_vtt(srt, -10.0);
    assert!(vtt_back.contains("00:00:50.000 --> 00:00:55.000"));

    // Clamping to 0
    let vtt_clamp = SubtitleService::srt_to_vtt(srt, -100.0);
    assert!(vtt_clamp.contains("00:00:00.000 --> 00:00:00.000"));
}

#[test]
fn test_detect_subtitle_language() {
    let hindi = "1\n00:00:01,000 --> 00:00:04,000\nनमस्ते दुनिया, यह हिंदी में एक उपशीर्षक है।\n";
    assert_eq!(SubtitleService::detect_subtitle_language(hindi), "hi");

    let russian = "1\n00:00:01,000 --> 00:00:04,000\nПривет, мир! Это русские субтитры.\n";
    assert_eq!(SubtitleService::detect_subtitle_language(russian), "ru");

    let english = "1\n00:00:01,000 --> 00:00:04,000\nThis is a test subtitle with english words and sentences that should match vocabulary.\n";
    assert_eq!(SubtitleService::detect_subtitle_language(english), "en");

    let spanish = "1\n00:00:01,000 --> 00:00:04,000\nHola que tal es una pelicula con mas palabras para ver bien.\n";
    assert_eq!(SubtitleService::detect_subtitle_language(spanish), "es");

    let unknown = "1\n00:00:01,000 --> 00:00:04,000\n1234 5678 9999\n";
    assert_eq!(SubtitleService::detect_subtitle_language(unknown), "und");
}

#[test]
fn test_get_short_movie_name() {
    let path = PathBuf::from("D:/Flicks/Gladiator.2000.1080p.BluRay.mkv");
    let short = SubtitleService::get_short_movie_name(&path);
    assert_eq!(short, "gladiator_2000_1080p_bluray");
}

#[tokio::test]
async fn test_stream_subtitle_vtt_200() {
    let harness = setup_subtitle_test().await;

    // Create dummy video and sidecar subtitle
    let video_file = harness.test_dir.join("sample_movie.mp4");
    fs::write(&video_file, b"fake video bytes").unwrap();

    let sub_file = harness.test_dir.join("sample_movie.en.srt");
    let srt_content = "1\n00:00:02,000 --> 00:00:05,000\nDirect streaming subtitle test.\n";
    fs::write(&sub_file, srt_content).unwrap();

    let req = Request::builder()
        .method(Method::GET)
        .uri("/subtitles/sample_movie.mp4/sample_movie.en.srt")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "text/vtt; charset=utf-8"
    );
    assert_eq!(
        res.headers().get("access-control-allow-origin").unwrap(),
        "*"
    );
    assert_eq!(
        res.headers().get("cross-origin-resource-policy").unwrap(),
        "cross-origin"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let text = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(text.starts_with("WEBVTT\n"));
    assert!(text.contains("00:00:02.000 --> 00:00:05.000"));
    assert!(text.contains("Direct streaming subtitle test."));
}

#[tokio::test]
async fn test_stream_subtitle_with_offset() {
    let harness = setup_subtitle_test().await;

    let video_file = harness.test_dir.join("offset_movie.mp4");
    fs::write(&video_file, b"fake video bytes").unwrap();

    let sub_file = harness.test_dir.join("offset_movie.en.srt");
    let srt_content = "1\n00:00:10,000 --> 00:00:15,000\nTesting offset.\n";
    fs::write(&sub_file, srt_content).unwrap();

    let req = Request::builder()
        .method(Method::GET)
        .uri("/subtitles/offset_movie.mp4/offset_movie.en.srt?offset=3.5")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let text = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(text.contains("00:00:13.500 --> 00:00:18.500"));
}

#[tokio::test]
async fn test_stream_subtitle_head_request() {
    let harness = setup_subtitle_test().await;

    let video_file = harness.test_dir.join("head_movie.mp4");
    fs::write(&video_file, b"fake video bytes").unwrap();

    let sub_file = harness.test_dir.join("head_movie.en.srt");
    fs::write(&sub_file, "1\n00:00:01,000 --> 00:00:02,000\nHead test\n").unwrap();

    let req = Request::builder()
        .method(Method::HEAD)
        .uri("/subtitles/head_movie.mp4/head_movie.en.srt")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "text/vtt; charset=utf-8"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(bytes.len(), 0);
}

#[tokio::test]
async fn test_stream_subtitle_options_cors() {
    let harness = setup_subtitle_test().await;

    let req = Request::builder()
        .method(Method::OPTIONS)
        .uri("/subtitles/sample.mp4/sample.en.srt")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get("access-control-allow-origin").unwrap(),
        "*"
    );
}

#[tokio::test]
async fn test_list_subtitles_catalog() {
    let harness = setup_subtitle_test().await;

    let video_file = harness.test_dir.join("gladiator.mp4");
    fs::write(&video_file, b"fake video bytes").unwrap();

    let sub_en = harness.test_dir.join("gladiator.en.srt");
    fs::write(
        &sub_en,
        "1\n00:00:01,000 --> 00:00:02,000\nThis is the english subtitle track.\n",
    )
    .unwrap();

    let sub_hi = harness.test_dir.join("gladiator.hi.srt");
    fs::write(
        &sub_hi,
        "1\n00:00:01,000 --> 00:00:02,000\nनमस्ते दुनिया यह हिंदी है।\n",
    )
    .unwrap();

    let req = Request::builder()
        .method(Method::GET)
        .uri("/api/subtitles/gladiator.mp4")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let catalog: SubtitleListResponse = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(catalog.tracks.len(), 2);

    let en_track = catalog.tracks.iter().find(|t| t.lang == "en").unwrap();
    assert_eq!(en_track.label, "English (Local)");
    assert!(en_track.default);
    assert_eq!(en_track.src, "/subtitles/gladiator.mp4/gladiator.en.srt");

    let hi_track = catalog.tracks.iter().find(|t| t.lang == "hi").unwrap();
    assert_eq!(hi_track.label, "Hindi (Local)");
    assert!(!hi_track.default);
}

#[tokio::test]
async fn test_upload_subtitle_multipart() {
    let harness = setup_subtitle_test().await;

    let video_file = harness.test_dir.join("avatar.mp4");
    fs::write(&video_file, b"fake video bytes").unwrap();

    let boundary = "---------------------------12345678901234567890";
    let spanish_srt = "1\r\n00:00:01,000 --> 00:00:04,000\r\nHola amigo, esta es una pelicula con muchas palabras en español para verificar.\r\n";

    let body = format!(
        "--{boundary}\r\n\
         Content-Disposition: form-data; name=\"subtitle\"; filename=\"avatar_raw.srt\"\r\n\
         Content-Type: text/plain\r\n\r\n\
         {spanish_srt}\r\n\
         --{boundary}--\r\n"
    );

    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/upload-subtitle/avatar.mp4")
        .header(
            header::CONTENT_TYPE,
            format!("multipart/form-data; boundary={boundary}"),
        )
        .body(Body::from(body))
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(json["success"], true);
    assert_eq!(json["language"], "es");
    assert_eq!(json["filename"], "avatar_es_1.srt");

    // Verify file actually exists on disk next to video
    let saved_path = harness.test_dir.join("avatar_es_1.srt");
    assert!(saved_path.is_file());
    let saved_content = fs::read_to_string(saved_path).unwrap();
    assert!(saved_content.contains("Hola amigo"));
}

#[tokio::test]
async fn test_upload_subtitle_invalid_extension() {
    let harness = setup_subtitle_test().await;

    let video_file = harness.test_dir.join("inception.mp4");
    fs::write(&video_file, b"fake video bytes").unwrap();

    let boundary = "---------------------------12345678901234567890";
    let body = format!(
        "--{boundary}\r\n\
         Content-Disposition: form-data; name=\"subtitle\"; filename=\"inception.exe\"\r\n\
         Content-Type: application/octet-stream\r\n\r\n\
         bad content\r\n\
         --{boundary}--\r\n"
    );

    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/upload-subtitle/inception.mp4")
        .header(
            header::CONTENT_TYPE,
            format!("multipart/form-data; boundary={boundary}"),
        )
        .body(Body::from(body))
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
}

#[tokio::test]
async fn test_subtitle_traversal_denied() {
    let harness = setup_subtitle_test().await;

    let video_file = harness.test_dir.join("secure.mp4");
    fs::write(&video_file, b"fake video bytes").unwrap();

    let req = Request::builder()
        .method(Method::GET)
        .uri("/subtitles/secure.mp4/..%2Fsecret.srt")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert!(
        res.status() == StatusCode::FORBIDDEN
            || res.status() == StatusCode::NOT_FOUND
            || res.status() == StatusCode::BAD_REQUEST
    );
}

#[test]
fn test_compute_opensubtitles_hash_under_size() {
    let tmp = std::env::temp_dir().join(format!("small_{}.bin", std::process::id()));
    fs::write(&tmp, b"small payload").unwrap();
    let res = SubtitleService::compute_opensubtitles_hash(&tmp);
    let _ = fs::remove_file(&tmp);
    assert_eq!(res, None);
}

#[test]
fn test_compute_opensubtitles_hash_exact() {
    let tmp = std::env::temp_dir().join(format!("dummy_video_{}.bin", std::process::id()));
    let dummy = vec![1u8; 131072]; // 128KB exactly
    fs::write(&tmp, &dummy).unwrap();
    let res = SubtitleService::compute_opensubtitles_hash(&tmp);
    let _ = fs::remove_file(&tmp);
    assert!(res.is_some());
    let (hash, size) = res.unwrap();
    assert_eq!(size, 131072);
    assert_eq!(hash.len(), 16);
}

#[tokio::test]
async fn test_embedded_subtitle_cached_serving() {
    use sha2::{Digest, Sha256};
    let harness = setup_subtitle_test().await;

    let video_file = harness.test_dir.join("matrix.mkv");
    fs::write(&video_file, b"fake video bytes").unwrap();

    let canon_video = video_file.canonicalize().unwrap();
    let meta = fs::metadata(&canon_video).unwrap();
    let size = meta.len();
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos())
        .unwrap_or(0);

    let stamp = {
        let path_str = canon_video.to_string_lossy();
        let clean_path = path_str.strip_prefix(r"\\?\").unwrap_or(&path_str);
        format!("{}:{}:{}", clean_path, size, mtime)
    };
    let mut hasher = Sha256::new();
    hasher.update(stamp.as_bytes());
    let short_hash = &hex::encode(hasher.finalize())[..16];

    let embed_dir = harness.cache_dir.join("subtitles").join("embedded");
    fs::create_dir_all(&embed_dir).unwrap();
    let vtt_file = embed_dir.join(format!("{}_2.vtt", short_hash));
    fs::write(&vtt_file, b"WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nFollow the white rabbit.\n").unwrap();

    let req = Request::builder()
        .method(Method::GET)
        .uri("/subtitles/embedded/matrix.mkv/2.vtt")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "text/vtt; charset=utf-8"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let text = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(text.contains("Follow the white rabbit."));
}

#[tokio::test]
async fn test_online_subtitle_cached_serving() {
    use sha2::{Digest, Sha256};
    let harness = setup_subtitle_test().await;

    let video_file = harness.test_dir.join("space.mp4");
    fs::write(&video_file, b"fake video bytes").unwrap();

    let canon_video = video_file.canonicalize().unwrap();
    let meta = fs::metadata(&canon_video).unwrap();
    let size = meta.len();
    let stamp = {
        let path_str = canon_video.to_string_lossy();
        let clean_path = path_str.strip_prefix(r"\\?\").unwrap_or(&path_str);
        format!("{}:{}", clean_path, size)
    };
    let mut hasher = Sha256::new();
    hasher.update(stamp.as_bytes());
    let short_hash = &hex::encode(hasher.finalize())[..16];

    let online_dir = harness.cache_dir.join("subtitles").join("online");
    fs::create_dir_all(&online_dir).unwrap();
    let vtt_file = online_dir.join(format!("{}.vtt", short_hash));
    fs::write(&vtt_file, b"WEBVTT\n\n00:00:05.000 --> 00:00:08.000\nI am sorry Dave, I cannot do that.\n").unwrap();

    let req = Request::builder()
        .method(Method::GET)
        .uri("/subtitles/online/space.mp4.vtt")
        .body(Body::empty())
        .unwrap();

    let res = harness.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "text/vtt; charset=utf-8"
    );

    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let text = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(text.contains("I am sorry Dave, I cannot do that."));
}
