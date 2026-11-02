use media_server_api::db;
use media_server_api::scanner::ScannerEngine;
use media_server_api::services::movie_service::MovieService;
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
    assert!(!ScannerEngine::is_video_file(Path::new("init.mp4")));
    assert!(!ScannerEngine::is_video_file(Path::new("Movie/Init.MP4")));
    assert!(!ScannerEngine::is_video_file(Path::new("init_chunk_0.mp4")));
    assert!(!ScannerEngine::is_video_file(Path::new("init_1.mp4")));
    assert!(!ScannerEngine::is_video_file(Path::new("init_copyts.mp4")));
    assert!(ScannerEngine::is_video_file(Path::new("Initial D.mp4")));
    assert!(ScannerEngine::is_video_file(Path::new("movie-init.mp4")));
}

#[tokio::test]
async fn test_hls_init_artifacts_are_hidden_and_pruned_from_catalog() {
    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Database connection");
    let temp_root =
        std::env::temp_dir().join(format!("ms_hls_init_cleanup_{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp_root);
    let fixture_dir = format!("hls_init_fixture_{}", std::process::id());
    let relative_dir = PathBuf::from(&fixture_dir);
    let init_filename = relative_dir
        .join("init.mp4")
        .to_string_lossy()
        .replace('\\', "/");
    let chunk_filename = relative_dir
        .join("init_chunk_0.mp4")
        .to_string_lossy()
        .replace('\\', "/");
    let legacy_fixture_filename = relative_dir
        .join("init_copyts.mp4")
        .to_string_lossy()
        .replace('\\', "/");
    let init_path = temp_root.join(&init_filename);
    let chunk_path = temp_root.join(&chunk_filename);
    let legacy_fixture_path = temp_root.join(&legacy_fixture_filename);
    fs::create_dir_all(init_path.parent().unwrap()).unwrap();
    fs::write(&init_path, b"init data").unwrap();
    fs::write(&chunk_path, b"chunk init data").unwrap();
    fs::write(&legacy_fixture_path, b"legacy init fixture").unwrap();

    for filename in [&init_filename, &chunk_filename, &legacy_fixture_filename] {
        sqlx::query("INSERT INTO movies (filename, title) VALUES ($1, 'HLS init artifact')")
            .bind(filename)
            .execute(&pool)
            .await
            .unwrap();
    }
    sqlx::query("INSERT INTO progress (filename, position, duration) VALUES ($1, 12, 100)")
        .bind(&init_filename)
        .execute(&pool)
        .await
        .unwrap();

    let catalog = MovieService::list_movies(&pool, None, None, None, None)
        .await
        .expect("Catalog query succeeds");
    assert!(!catalog
        .movies
        .iter()
        .any(|movie| movie.filename == init_filename));
    assert!(!catalog
        .movies
        .iter()
        .any(|movie| movie.filename == chunk_filename));
    assert!(!catalog
        .movies
        .iter()
        .any(|movie| movie.filename == legacy_fixture_filename));

    let mut roots = config.media_roots.clone();
    roots.push(temp_root.clone());
    let pruned = ScannerEngine::reconcile_orphans(&pool, &roots)
        .await
        .expect("Reconciliation succeeds");
    assert!(pruned >= 3, "all generated init records should be pruned");

    for filename in [&init_filename, &chunk_filename, &legacy_fixture_filename] {
        let row: Option<String> =
            sqlx::query_scalar("SELECT filename FROM movies WHERE filename = $1")
                .bind(filename)
                .fetch_optional(&pool)
                .await
                .unwrap();
        assert!(
            row.is_none(),
            "generated init catalog row should be removed"
        );
    }
    let progress_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM progress WHERE filename = $1")
            .bind(&init_filename)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(progress_count, 0);
    assert!(
        init_path.exists(),
        "cleanup must leave the physical file alone"
    );
    assert!(
        chunk_path.exists(),
        "cleanup must leave the physical file alone"
    );
    assert!(
        legacy_fixture_path.exists(),
        "cleanup must leave the physical file alone"
    );

    let _ = fs::remove_dir_all(&temp_root);
}

#[test]
fn test_compute_relative_path() {
    let root = PathBuf::from(r"D:\Flicks");
    let roots = vec![root.clone()];

    let file1 = root.join("Movie.mp4");
    assert_eq!(
        ScannerEngine::compute_relative_path(&file1, &roots),
        "Movie.mp4"
    );

    let file2 = root.join("Subfolder").join("Movie.mkv");
    assert_eq!(
        ScannerEngine::compute_relative_path(&file2, &roots),
        "Subfolder/Movie.mkv"
    );
}

#[tokio::test]
async fn test_reconcile_orphans_prunes_missing_files() {
    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Database connection");

    let temp_root =
        std::env::temp_dir().join(format!("rust_test_scan_reconcile_{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp_root);
    fs::create_dir_all(&temp_root).unwrap();

    let orphan_filename = format!("Orphan_Test_Movie_{}.mkv", std::process::id());
    let present_filename = format!("Present_Test_Movie_{}.mkv", std::process::id());

    // A file that genuinely exists on disk, and a catalog row pointing at it.
    // The previous version of this test asserted against a hardcoded
    // production title ("Oculus.2013..."), which meant the test broke if that
    // title was ever removed from the library, and it wrote its fixture into
    // the production database. The intent - a row whose file still exists is
    // preserved, a row whose file is gone is pruned - is now expressed with
    // a fixture the test owns.
    fs::write(temp_root.join(&present_filename), b"not a real video").unwrap();

    for (filename, title) in [
        (&orphan_filename, "Orphan Test Movie"),
        (&present_filename, "Present Test Movie"),
    ] {
        sqlx::query(
            "INSERT INTO movies (filename, title, year) VALUES ($1, $2, $3) ON CONFLICT (filename) DO NOTHING",
        )
        .bind(filename)
        .bind(title)
        .bind(2024)
        .execute(&pool)
        .await
        .unwrap();
    }

    // Reconcile against the live roots + temp_root, so real library movies
    // are preserved and only the orphan is pruned.
    let mut roots = config.media_roots.clone();
    roots.push(temp_root.clone());
    let pruned = ScannerEngine::reconcile_orphans(&pool, &roots)
        .await
        .expect("Reconciliation succeeds");

    assert!(
        pruned >= 1,
        "Expected at least the orphan test movie to be pruned"
    );

    // Verify orphan is gone from PostgreSQL
    let row = sqlx::query_as::<_, (String,)>("SELECT filename FROM movies WHERE filename = $1")
        .bind(&orphan_filename)
        .fetch_optional(&pool)
        .await
        .unwrap();

    assert!(
        row.is_none(),
        "Orphaned movie record was pruned as expected (Decision 1A)"
    );

    // Verify the movie whose file still exists is preserved
    let present_row =
        sqlx::query_as::<_, (String,)>("SELECT filename FROM movies WHERE filename = $1")
            .bind(&present_filename)
            .fetch_optional(&pool)
            .await
            .unwrap();
    assert!(
        present_row.is_some(),
        "A movie whose file still exists must be preserved and not pruned"
    );

    // Teardown: leave no phantom rows behind.
    for filename in [&orphan_filename, &present_filename] {
        let _ = sqlx::query("DELETE FROM movies WHERE filename = $1")
            .bind(filename)
            .execute(&pool)
            .await;
    }

    let _ = fs::remove_dir_all(&temp_root);
}
