use media_server_api::config::AppConfig;
use media_server_api::db;
use media_server_api::scanner::ScannerEngine;
use std::fs;
use std::path::{Path, PathBuf};

#[test]
fn test_is_video_file() {
    assert!(ScannerEngine::is_video_file(Path::new("movie.mp4")));
    assert!(ScannerEngine::is_video_file(Path::new("movie.mkv")));
    assert!(ScannerEngine::is_video_file(Path::new("movie.webm")));
    assert!(ScannerEngine::is_video_file(Path::new("movie.mov")));
    assert!(ScannerEngine::is_video_file(Path::new("movie.avi")));
    assert!(ScannerEngine::is_video_file(Path::new("movie.m4v")));

    assert!(!ScannerEngine::is_video_file(Path::new("subtitles.srt")));
    assert!(!ScannerEngine::is_video_file(Path::new("info.nfo")));
    assert!(!ScannerEngine::is_video_file(Path::new("poster.jpg")));
    assert!(!ScannerEngine::is_video_file(Path::new("readme.txt")));
}

#[test]
fn test_compute_relative_path() {
    let root = PathBuf::from(r"D:\Flicks");
    let roots = vec![root.clone()];

    let file1 = root.join("Movie.mp4");
    assert_eq!(ScannerEngine::compute_relative_path(&file1, &roots), "Movie.mp4");

    let file2 = root.join("Subfolder").join("Movie.mkv");
    assert_eq!(
        ScannerEngine::compute_relative_path(&file2, &roots),
        "Subfolder/Movie.mkv"
    );
}

#[tokio::test]
async fn test_reconcile_orphans_prunes_missing_files() {
    let config = AppConfig::from_env();
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Database connection");

    let temp_root = std::env::temp_dir().join(format!("rust_test_scan_reconcile_{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp_root);
    fs::create_dir_all(&temp_root).unwrap();

    let orphan_filename = format!("Orphan_Test_Movie_{}.mkv", std::process::id());

    // Insert orphan record into PostgreSQL
    sqlx::query(
        "INSERT INTO movies (filename, title, year) VALUES ($1, $2, $3) ON CONFLICT (filename) DO NOTHING"
    )
    .bind(&orphan_filename)
    .bind("Orphan Test Movie")
    .bind(2024)
    .execute(&pool)
    .await
    .unwrap();

    // Reconcile against live roots + temp_root (so real movies are preserved and only orphan is pruned)
    let mut roots = config.media_roots.clone();
    roots.push(temp_root.clone());
    let pruned = ScannerEngine::reconcile_orphans(&pool, &roots)
        .await
        .expect("Reconciliation succeeds");

    assert!(pruned >= 1, "Expected at least the orphan test movie to be pruned");

    // Verify orphan is gone from PostgreSQL
    let row = sqlx::query_as::<_, (String,)>("SELECT filename FROM movies WHERE filename = $1")
        .bind(&orphan_filename)
        .fetch_optional(&pool)
        .await
        .unwrap();

    assert!(row.is_none(), "Orphaned movie record was pruned as expected (Decision 1A)");

    // Verify real library movie is preserved
    let real_movie = sqlx::query_as::<_, (String,)>("SELECT filename FROM movies WHERE filename = 'Oculus.2013.1080p.BluRay.x264.YIFY.mp4'")
        .fetch_optional(&pool)
        .await
        .unwrap();
    assert!(real_movie.is_some(), "Production movie was preserved and not pruned");

    let _ = fs::remove_dir_all(&temp_root);
}
