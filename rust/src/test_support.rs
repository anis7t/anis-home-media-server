//! Test-only support for the Rust integration suite.
//!
//! ## Why this module exists
//!
//! Every integration test in `rust/tests/` built its config with
//! `AppConfig::from_env()`. That helper falls back to
//! `postgresql://postgres:postgres@127.0.0.1:5432/media_server` when
//! `MEDIA_SERVER_DATABASE_URL` is unset - and on this host it *is* unset, so
//! the entire suite ran against the **production** database.
//!
//! Two things followed from that, and both are real defects rather than
//! hygiene complaints:
//!
//! 1. A test that inserted a row and failed before its cleanup left that row
//!    in the live catalog. The `qr_device_auth_flow_test` did exactly this:
//!    it inserted `users(google_sub='sub_phone_user')` with a plain `INSERT`
//!    and never removed it, so it passed on a clean database and then failed
//!    on every subsequent run with
//!    `23505 duplicate key value violates unique constraint "users_google_sub_key"`.
//! 2. A test failure in production is an outage in production. The test
//!    suite is a development tool and must not be able to damage the library.
//!
//! `test_config()` provisions a dedicated `media_server_test` database and
//! returns a config pointed at it. The schema is created by
//! [`crate::db::create_pool`], which already calls `ensure_schema`.
//!
//! ## What is and is not isolated
//!
//! - **The database is isolated.** Every test that writes metadata now writes
//!   to `media_server_test`.
//! - **The cache is isolated.** `cache_dir` is redirected to a per-process
//!   temporary directory, so no test writes into the production HLS or
//!   preview cache.
//! - **The media roots are NOT isolated, and must not be.** They are the
//!   library itself, read-only to the tests. Several contracts
//!   (`media_info`, `api/contracts`) are only meaningful against a real,
//!   probeable video file, so those tests discover a real file from the
//!   roots and seed a catalog row for it in the test database. The metadata
//!   is isolated; the bytes are the real ones.

use crate::config::AppConfig;
use sqlx::{Connection, Executor, PgConnection};

/// Default URL of the dedicated test database.
///
/// Override with `MEDIA_SERVER_TEST_DATABASE_URL` when the PostgreSQL server
/// is not the local default (different port, different credentials, or a
/// remote instance).
pub const DEFAULT_TEST_DATABASE_URL: &str =
    "postgresql://postgres:postgres@127.0.0.1:5432/media_server_test";

/// Resolve the test database URL from the environment, falling back to
/// [`DEFAULT_TEST_DATABASE_URL`].
pub fn test_database_url() -> String {
    std::env::var("MEDIA_SERVER_TEST_DATABASE_URL")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| DEFAULT_TEST_DATABASE_URL.to_string())
}

/// Create the test database if it does not exist yet.
///
/// `CREATE DATABASE` cannot run inside a transaction block, so this uses a
/// bare connection rather than a pool. The existence check runs first, and a
/// concurrent creation is tolerated, because `CREATE DATABASE` would
/// otherwise abort the transaction it was issued in.
pub async fn ensure_test_database(url: &str) -> Result<(), sqlx::Error> {
    let parsed =
        url::Url::parse(url).map_err(|e| sqlx::Error::Configuration(Box::new(e)))?;

    let db_name = parsed.path().trim_start_matches('/').to_string();
    if db_name.is_empty() {
        return Err(sqlx::Error::Configuration(
            "test database URL has no database name".into(),
        ));
    }

    // Maintenance connection: the same server, the default `postgres` database.
    let mut maintenance = parsed.clone();
    maintenance.set_path("/postgres");

    let mut conn = PgConnection::connect(maintenance.as_str()).await?;

    let exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1)")
            .bind(&db_name)
            .fetch_one(&mut conn)
            .await?;

    if !exists {
        // Quoted as an identifier. The name comes from our own configuration
        // rather than from user input, but the quoting is still the correct
        // way to express a database name.
        let ident = format!("\"{}\"", db_name.replace('"', "\"\""));
        match conn
            .execute(sqlx::raw_sql(&format!("CREATE DATABASE {}", ident)))
            .await
        {
            Ok(_) => {}
            // 42P04 = duplicate_database. Another test process won the race.
            Err(sqlx::Error::Database(ref e)) if e.code().as_deref() == Some("42P04") => {}
            Err(e) => return Err(e),
        }
    }

    Ok(())
}

/// Build an `AppConfig` pointed at the dedicated test database.
///
/// The database is provisioned on demand. The production `media_roots` and
/// `static_dir` are preserved (the library and the built SPA are read-only
/// inputs to the tests); `database_url` and `cache_dir` are redirected.
pub async fn test_config() -> AppConfig {
    let mut config = AppConfig::from_env();

    let url = test_database_url();
    ensure_test_database(&url)
        .await
        .expect("the dedicated test database must be provisionable");
    config.database_url = url;

    // Keep every test away from the production HLS and preview cache.
    let cache_dir = std::env::temp_dir().join(format!("ms_test_cache_{}", std::process::id()));
    let _ = std::fs::create_dir_all(&cache_dir);
    config.cache_dir = cache_dir;

    config
}

/// Discover a real, probeable video file from the configured media roots.
///
/// The metadata tests need a genuine file: `ffprobe` has to return real
/// container and stream values, and a synthetic placeholder cannot provide
/// them. The file is only ever read.
pub fn discover_real_media_file(media_roots: &[std::path::PathBuf]) -> Option<std::path::PathBuf> {
    for root in media_roots {
        if !root.is_dir() {
            continue;
        }
        for entry in walkdir::WalkDir::new(root)
            .max_depth(3)
            .into_iter()
            .filter_map(|e| e.ok())
        {
            if !entry.file_type().is_file() {
                continue;
            }
            let path = entry.path();
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if matches!(ext.as_str(), "mp4" | "mkv" | "m4v" | "webm") {
                return Some(path.to_path_buf());
            }
        }
    }
    None
}

/// Seed the test database with a catalog row for a real, probeable media file.
///
/// The metadata contracts (`/api/movies`, `/api/movie/{filename}`,
/// `/api/media-info/{filename}`) are only meaningful against a genuine video
/// file: `ffprobe` has to return real container and stream values. The file
/// itself comes from the read-only production media roots - only the
/// *metadata* is written, and only into the isolated test database.
///
/// Returns the catalog filename (the path relative to its media root), or
/// `None` when the library has no video file to offer.
pub async fn seed_real_media_row(
    pool: &sqlx::PgPool,
    media_roots: &[std::path::PathBuf],
) -> Option<String> {
    let path = discover_real_media_file(media_roots)?;
    let filename = crate::scanner::ScannerEngine::compute_relative_path(&path, media_roots);

    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| filename.clone());
    let title = stem.replace(['_', '.'], " ").trim().to_string();
    let year = title
        .split_whitespace()
        .find_map(|w| {
            let digits: String = w.chars().filter(|c| c.is_ascii_digit()).collect();
            if digits.len() == 4 {
                digits.parse::<i32>().ok()
            } else {
                None
            }
        });

    sqlx::query(
        r#"
        INSERT INTO movies (filename, title, year)
        VALUES ($1, $2, $3)
        ON CONFLICT (filename) DO UPDATE SET title = EXCLUDED.title
        "#,
    )
    .bind(&filename)
    .bind(&title)
    .bind(year)
    .execute(pool)
    .await
    .expect("seeding a catalog row must succeed");

    Some(filename)
}

/// Remove a seeded catalog row, so the test database holds no residue.
pub async fn remove_seeded_media_row(pool: &sqlx::PgPool, filename: &str) {
    let _ = sqlx::query("DELETE FROM movies WHERE filename = $1")
        .bind(filename)
        .execute(pool)
        .await;
}
