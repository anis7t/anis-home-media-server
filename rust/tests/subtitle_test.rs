use media_server_api::scanner::ScannerReport;
use media_server_api::services::scan_service::ScanResponse;
use media_server_api::services::subtitle_service::SubtitleService;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

struct TestDir(PathBuf);

impl TestDir {
    fn new(name: &str) -> Self {
        let p = std::env::temp_dir().join(format!(
            "ms_test_{}_{}_{}",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        Self(p)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn test_opensubtitles_hash_computation() {
    let dir = TestDir::new("hash");
    let video_path = dir.path().join("sample_movie.mp4");

    // Write a file > 128KB (e.g. 200KB)
    let size = 200 * 1024;
    let mut file = fs::File::create(&video_path).unwrap();
    let data = vec![0xABu8; size];
    file.write_all(&data).unwrap();
    drop(file);

    let res = SubtitleService::compute_opensubtitles_hash(&video_path);
    assert!(res.is_some(), "Must successfully compute hash for file >= 128KB");

    let (hash_str, filesize) = res.unwrap();
    assert_eq!(filesize, size as u64);
    assert_eq!(hash_str.len(), 16, "OpenSubtitles hash must be 16-character hex string");

    // For files < 128KB, should return None
    let small_path = dir.path().join("small.mp4");
    fs::write(&small_path, b"short").unwrap();
    assert!(SubtitleService::compute_opensubtitles_hash(&small_path).is_none());
}

#[tokio::test]
async fn test_has_english_subtitles_detection() {
    let dir = TestDir::new("detect");
    let roots = vec![dir.path().to_path_buf()];
    let cache_dir = dir.path().join("cache");
    fs::create_dir_all(&cache_dir).unwrap();

    let movie_dir = dir.path().join("ActionMovie (2024)");
    fs::create_dir_all(&movie_dir).unwrap();
    let video_path = movie_dir.join("ActionMovie.mkv");
    // Write 150KB dummy video
    fs::write(&video_path, vec![0u8; 150 * 1024]).unwrap();

    let rel_filename = "ActionMovie (2024)/ActionMovie.mkv";

    // 1. Without any subtitles -> false
    assert!(!SubtitleService::has_english_subtitles(&video_path, rel_filename, &roots, &cache_dir).await);

    // 2. Add an English sidecar `.en.srt` -> true
    let sidecar_srt = movie_dir.join("ActionMovie.en.srt");
    fs::write(
        &sidecar_srt,
        "1\n00:00:01,000 --> 00:00:04,000\nThis is the beginning of the movie and we are with you.\n",
    )
    .unwrap();

    assert!(SubtitleService::has_english_subtitles(&video_path, rel_filename, &roots, &cache_dir).await);

    // 3. Remove sidecar, but simulate pre-cached online OpenSubtitles track -> true
    fs::remove_file(&sidecar_srt).unwrap();
    assert!(!SubtitleService::has_english_subtitles(&video_path, rel_filename, &roots, &cache_dir).await);

    // Compute online short_hash
    let meta = fs::metadata(&video_path).unwrap();
    let size = meta.len();
    let path_str = video_path.to_string_lossy();
    let clean_path = path_str.strip_prefix(r"\\?\").unwrap_or(&path_str);
    let stamp = format!("{}:{}", clean_path, size);
    let mut hasher = Sha256::new();
    hasher.update(stamp.as_bytes());
    let short_hash = &hex::encode(hasher.finalize())[..16];

    let online_dir = cache_dir.join("subtitles").join("online");
    fs::create_dir_all(&online_dir).unwrap();
    let online_vtt = online_dir.join(format!("{}.vtt", short_hash));
    fs::write(&online_vtt, "WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nCached Subtitle\n").unwrap();

    assert!(SubtitleService::has_english_subtitles(&video_path, rel_filename, &roots, &cache_dir).await);
}

#[tokio::test]
async fn test_negative_match_cache_fast_path() {
    let dir = TestDir::new("negcache");
    let cache_dir = dir.path().join("cache");
    let video_path = dir.path().join("MysteryMovie.mp4");
    fs::write(&video_path, vec![0x12u8; 150 * 1024]).unwrap();

    let meta = fs::metadata(&video_path).unwrap();
    let size = meta.len();
    let path_str = video_path.to_string_lossy();
    let clean_path = path_str.strip_prefix(r"\\?\").unwrap_or(&path_str);
    let stamp = format!("{}:{}", clean_path, size);
    let mut hasher = Sha256::new();
    hasher.update(stamp.as_bytes());
    let short_hash = &hex::encode(hasher.finalize())[..16];

    let online_dir = cache_dir.join("subtitles").join("online");
    fs::create_dir_all(&online_dir).unwrap();
    let nomatch_file = online_dir.join(format!("{}.nomatch", short_hash));

    // Place a 24h negative-match cache marker
    fs::write(&nomatch_file, b"no_match").unwrap();

    let start = std::time::Instant::now();
    let res = SubtitleService::fetch_online_subtitle(&video_path, "Mystery Movie", &cache_dir).await;
    let elapsed = start.elapsed();

    // Must return None instantly (< 100ms) without attempting external HTTP queries
    assert!(res.is_none());
    assert!(elapsed < std::time::Duration::from_millis(100), "Negative match cache must return instantly, took {:?}", elapsed);
}

#[tokio::test]
async fn test_ensure_subtitles_skips_when_english_present() {
    let dir = TestDir::new("skip");
    let roots = vec![dir.path().to_path_buf()];
    let cache_dir = dir.path().join("cache");
    let video_path = dir.path().join("Drama.mkv");
    fs::write(&video_path, vec![0u8; 150 * 1024]).unwrap();

    // Create an English sidecar
    let sidecar = dir.path().join("Drama.en.vtt");
    fs::write(
        &sidecar,
        "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nThis is the beginning of the movie and we are with you.\n",
    )
    .unwrap();

    let acquired = SubtitleService::ensure_subtitles_for_movie(
        &video_path,
        "Drama.mkv",
        "Drama",
        &roots,
        &cache_dir,
    )
    .await;

    // Should return false (skipped because English subtitles already exist)
    assert!(!acquired, "Must skip subtitle acquisition when English subtitle already exists");
}

#[test]
fn test_scanner_report_telemetry_includes_subtitles() {
    let mut report = ScannerReport::default();
    report.files_discovered = 10;
    report.subtitles_acquired = 3;

    assert_eq!(report.subtitles_acquired, 3);

    let res = ScanResponse {
        status: "idle".to_string(),
        busy: false,
        files_discovered: report.files_discovered,
        unindexed_discovered: 0,
        movies_indexed: 0,
        orphans_pruned: 0,
        subtitles_acquired: report.subtitles_acquired,
        errors: 0,
        transcodes_queued: 0,
        transcodes_started: 0,
        transcodes_skipped: 0,
        transcodes_errors: 0,
    };

    let json = serde_json::to_string(&res).unwrap();
    assert!(json.contains("\"subtitles_acquired\":3"));
}
