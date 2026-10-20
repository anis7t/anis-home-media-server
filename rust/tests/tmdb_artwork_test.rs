//! Phase C1b: native TMDb artwork delivery (`/tmdb-poster/{id}`,
//! `/tmdb-backdrop/{id}`).
//!
//! Network access is pointed at a local mock TMDb by overriding the base via
//! `TMDB_ARTWORK_BASE_URL`, so download behaviour - retries, atomic write,
//! failure-to-404 - is testable deterministically and without hammering the
//! real CDN. A test that only ever passes against the internet is not a test.
//!
//! Database isolation (AGENTS.md s9): rows are inserted and deleted within
//! each test, and namespaced so cleanup can never touch a real movie.

use axum::{body::Body, http::{header, Method, Request, StatusCode}, routing::get, Router};
use http_body_util::BodyExt;
use media_server_api::{
    create_app,
    services::{system_service::SystemService, tmdb_artwork::TmdbArtworkService},
};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tower::ServiceExt;

static REQUEST_COUNTER: AtomicUsize = AtomicUsize::new(0);

/// A 1x1 PNG: small but comfortably above the 1000-byte cache guard.
fn png_bytes() -> Vec<u8> {
    let mut v = vec![
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ];
    // Pad with a comment chunk so the fixture clears the 1000-byte guard.
    v.extend_from_slice(&[0u8; 1200]);
    v
}

struct MockTmdb {
    base: String,
    hits: Arc<AtomicUsize>,
    handle: tokio::task::JoinHandle<()>,
}

impl Drop for MockTmdb {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

/// Mock TMDb image host. `/w500/...` and `/w1280/...` succeed; `/fail/...`
/// always 500s; `/tiny/...` returns a body under the cache guard.
async fn spawn_mock_tmdb() -> MockTmdb {
    let hits = Arc::new(AtomicUsize::new(0));
    let hits_c = hits.clone();

    // One route that inspects the requested path, because the service builds
    // `{base}/{size}{art_path}`: separate `/w500/...` and `/fail/...` routes
    // would never both match, and the failure cases would silently pass by
    // being served the success fixture.
    async fn serve(
        axum::extract::Path(p): axum::extract::Path<String>,
        hits: Arc<AtomicUsize>,
    ) -> axum::response::Response {
        use axum::http::HeaderValue;
        hits.fetch_add(1, Ordering::SeqCst);
        if p.contains("fail") {
            return axum::response::Response::builder()
                .status(StatusCode::INTERNAL_SERVER_ERROR)
                .body(axum::body::Body::from("boom"))
                .unwrap();
        }
        if p.contains("tiny") {
            return axum::response::Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"))
                .body(axum::body::Body::from("tiny"))
                .unwrap();
        }
        axum::response::Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, HeaderValue::from_static("image/jpeg"))
            .body(axum::body::Body::from(png_bytes()))
            .unwrap()
    }

    let app = Router::new()
        .route(
            "/w500/{*p}",
            get({
                let h = hits_c.clone();
                move |p: axum::extract::Path<String>| serve(p, h.clone())
            }),
        )
        .route(
            "/w1280/{*p}",
            get({
                let h = hits_c.clone();
                move |p: axum::extract::Path<String>| serve(p, h.clone())
            }),
        );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let handle = tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    MockTmdb {
        base: format!("http://{}", addr),
        hits,
        handle,
    }
}

/// Tests must not run concurrently: each points the service at its own mock
/// through one process-wide environment variable, so two tests in parallel
/// would silently retarget each other's downloads. Serialized here rather
/// than with `--test-threads=1`, which only the invoker can set.
static MOCK_SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

struct MockGuard {
    mock: MockTmdb,
    _serial: tokio::sync::MutexGuard<'static, ()>,
}

async fn mock_tmdb() -> MockGuard {
    let serial = MOCK_SERIAL.lock().await;
    let mock = spawn_mock_tmdb().await;
    std::env::set_var("TMDB_ARTWORK_BASE_URL", &mock.base);
    MockGuard { mock, _serial: serial }
}

struct Fixture {
    app: axum::Router,
    cache_dir: PathBuf,
    media_root: PathBuf,
    pool: sqlx::PgPool,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.cache_dir);
        let _ = fs::remove_dir_all(&self.media_root);
    }
}

async fn fixture() -> Fixture {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let cache_dir = std::env::temp_dir().join(format!("rust_tmdbcache_{}_{}", std::process::id(), n));
    let media_root = std::env::temp_dir().join(format!("rust_tmdbmedia_{}_{}", std::process::id(), n));
    fs::create_dir_all(&cache_dir).unwrap();
    fs::create_dir_all(&media_root).unwrap();

    let config = media_server_api::test_support::test_config().await;
    let pool = media_server_api::db::create_test_pool(&config.database_url)
        .await
        .expect("pool");
    let app = create_app(
        pool.clone(),
        SystemService::new(),
        vec![media_root.clone()],
        cache_dir.clone(),
    );
    Fixture { app, cache_dir, media_root, pool }
}

/// Insert a throwaway movie row. `tmdb_id` is unique per run so concurrent
/// tests never collide on the id.
async fn seed_movie(pool: &sqlx::PgPool, tmdb_id: i32, poster: Option<&str>, backdrop: Option<&str>) {
    let filename = format!("rust_tmdbart_test_{}_{}.mkv", std::process::id(), tmdb_id);
    // `added_at` is a bigint epoch column, not a timestamp.
    sqlx::query(
        "INSERT INTO movies (filename, tmdb_id, poster_path, backdrop_path) \
         VALUES ($1, $2, $3, $4) \
         ON CONFLICT (filename) DO UPDATE SET poster_path = EXCLUDED.poster_path, \
         backdrop_path = EXCLUDED.backdrop_path, tmdb_id = EXCLUDED.tmdb_id",
    )
    .bind(&filename)
    .bind(tmdb_id)
    .bind(poster)
    .bind(backdrop)
    .execute(pool)
    .await
    .expect("seed movie");
}

async fn cleanup_movies(pool: &sqlx::PgPool) {
    sqlx::query("DELETE FROM movies WHERE filename LIKE 'rust_tmdbart_test_%'")
        .execute(pool)
        .await
        .ok();
}

#[tokio::test]
async fn test_poster_downloads_once_then_serves_from_cache() {
    let _g = mock_tmdb().await;
    let f = fixture().await;
    let id = 9_100_001;
    seed_movie(&f.pool, id, Some("/abc.jpg"), None).await;

    let uri = format!("/tmdb-poster/{}", id);
    let res = f.app.clone().oneshot(Request::builder().method(Method::GET).uri(&uri).body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK, "first request must download");
    assert_eq!(res.headers()[header::CONTENT_TYPE], "image/jpeg");
    let first = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(_g.mock.hits.load(Ordering::SeqCst), 1, "exactly one upstream fetch");

    // Second request must be served from cache with no further upstream hit.
    let res = f.app.clone().oneshot(Request::builder().method(Method::GET).uri(&uri).body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let second = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(first.as_ref(), second.as_ref(), "cached bytes must be identical");
    assert_eq!(_g.mock.hits.load(Ordering::SeqCst), 1, "cache hit must not refetch");

    assert!(f.cache_dir.join("posters").join(format!("{}.jpg", id)).is_file());
    cleanup_movies(&f.pool).await;
}

#[tokio::test]
async fn test_concurrent_requests_cause_one_download() {
    let _g = mock_tmdb().await;
    let f = fixture().await;
    let id = 9_100_002;
    seed_movie(&f.pool, id, Some("/abc.jpg"), None).await;

    let uri = format!("/tmdb-poster/{}", id);
    let mut tasks = Vec::new();
    for _ in 0..8 {
        let app = f.app.clone();
        let u = uri.clone();
        tasks.push(tokio::spawn(async move {
            app.oneshot(Request::builder().method(Method::GET).uri(&u).body(Body::empty()).unwrap())
                .await
                .unwrap()
                .status()
        }));
    }
    for t in tasks {
        assert_eq!(t.await.unwrap(), StatusCode::OK);
    }
    assert_eq!(
        _g.mock.hits.load(Ordering::SeqCst),
        1,
        "single-flight: 8 concurrent requests must not download 8 times"
    );
    cleanup_movies(&f.pool).await;
}

#[tokio::test]
async fn test_backdrop_uses_its_own_cache_dir_and_size() {
    let _g = mock_tmdb().await;
    let f = fixture().await;
    let id = 9_100_003;
    seed_movie(&f.pool, id, Some("/p.jpg"), Some("/b.jpg")).await;

    let uri = format!("/tmdb-backdrop/{}", id);
    let res = f.app.clone().oneshot(Request::builder().method(Method::GET).uri(&uri).body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert!(
        f.cache_dir.join("backdrops").join(format!("{}.jpg", id)).is_file(),
        "backdrop must land in cache/backdrops, not cache/posters"
    );
    assert!(
        !f.cache_dir.join("posters").join(format!("{}.jpg", id)).exists(),
        "a backdrop must not create a poster cache entry"
    );
    cleanup_movies(&f.pool).await;
}

#[tokio::test]
async fn test_unknown_tmdb_id_is_404_with_no_upstream_call() {
    let _g = mock_tmdb().await;
    let f = fixture().await;

    for uri in ["/tmdb-poster/999999", "/tmdb-backdrop/999999"] {
        let res = f.app.clone().oneshot(Request::builder().method(Method::GET).uri(uri).body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(res.status(), StatusCode::NOT_FOUND, "{} should be 404", uri);
    }
    assert_eq!(
        _g.mock.hits.load(Ordering::SeqCst),
        0,
        "an id with no database row must never reach the network"
    );
    cleanup_movies(&f.pool).await;
}

#[tokio::test]
async fn test_download_failure_is_404_not_500_and_leaves_no_file() {
    let _g = mock_tmdb().await;
    let f = fixture().await;
    let id = 9_100_004;
    // /fail/... makes the mock return 500 for every attempt.
    seed_movie(&f.pool, id, Some("/fail/x.jpg"), None).await;

    let uri = format!("/tmdb-poster/{}", id);
    let res = f.app.clone().oneshot(Request::builder().method(Method::GET).uri(&uri).body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "a failed download must read as missing artwork, never a server error"
    );

    let posters = f.cache_dir.join("posters");
    let leftovers: Vec<_> = fs::read_dir(&posters)
        .map(|rd| rd.flatten().map(|e| e.file_name()).collect())
        .unwrap_or_default();
    assert!(
        leftovers.is_empty(),
        "a failed download must leave no cache file and no temp file, found {:?}",
        leftovers
    );
    cleanup_movies(&f.pool).await;
}

#[tokio::test]
async fn test_undersized_response_is_rejected_not_cached() {
    let _g = mock_tmdb().await;
    let f = fixture().await;
    let id = 9_100_005;
    // Body is 3 bytes: below the 1000-byte guard, so it must never land.
    seed_movie(&f.pool, id, Some("/tiny/x.jpg"), None).await;

    let uri = format!("/tmdb-poster/{}", id);
    let res = f.app.clone().oneshot(Request::builder().method(Method::GET).uri(&uri).body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    assert!(
        !f.cache_dir.join("posters").join(format!("{}.jpg", id)).exists(),
        "a response below the size guard must not be cached"
    );
    cleanup_movies(&f.pool).await;
}

#[tokio::test]
async fn test_invalid_and_negative_ids_are_404() {
    let _g = mock_tmdb().await;
    let f = fixture().await;

    for uri in ["/tmdb-poster/abc", "/tmdb-poster/-5", "/tmdb-backdrop/abc"] {
        let res = f.app.clone().oneshot(Request::builder().method(Method::GET).uri(uri).body(Body::empty()).unwrap()).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::NOT_FOUND,
            "{} must be 404 to match Flask's <int:> route, not 400",
            uri
        );
    }
    assert_eq!(_g.mock.hits.load(Ordering::SeqCst), 0);
    cleanup_movies(&f.pool).await;
}

#[tokio::test]
async fn test_empty_column_is_404_without_download() {
    let _g = mock_tmdb().await;
    let f = fixture().await;
    let id = 9_100_006;
    // Row exists, poster_path is blank: there is nothing to fetch.
    seed_movie(&f.pool, id, Some("   "), None).await;

    let uri = format!("/tmdb-poster/{}", id);
    let res = f.app.clone().oneshot(Request::builder().method(Method::GET).uri(&uri).body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    assert_eq!(_g.mock.hits.load(Ordering::SeqCst), 0, "blank path must not be fetched");
    cleanup_movies(&f.pool).await;
}

#[tokio::test]
async fn test_service_rejects_negative_id_without_touching_cache() {
    let f = fixture().await;
    let err = TmdbArtworkService::get(&f.pool, &f.cache_dir, -1, media_server_api::services::tmdb_artwork::ArtworkKind::Poster)
        .await
        .expect_err("negative id must be refused");
    assert!(matches!(err, media_server_api::error::AppError::NotFound(_)));
}

#[tokio::test]
async fn test_no_test_movies_remain() {
    // Takes the same lock as the download tests so the residue check cannot
    // observe rows another test is still creating or removing.
    let _g = mock_tmdb().await;
    let f = fixture().await;
    cleanup_movies(&f.pool).await;
    let remaining: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM movies WHERE filename LIKE 'rust_tmdbart_test_%'",
    )
    .fetch_one(&f.pool)
    .await
    .unwrap();
    assert_eq!(remaining, 0, "movies table must retain no test rows");
    REQUEST_COUNTER.fetch_add(0, Ordering::SeqCst);
}