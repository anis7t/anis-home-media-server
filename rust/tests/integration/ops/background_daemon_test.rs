use media_server_api::{
    db, services::scan_service::ScanService, services::storage_service::StorageService,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

#[tokio::test]
async fn test_scan_service_daemon_lifecycle_and_shutdown() {
    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");
    let media_roots = Arc::new(config.media_roots);
    let cache_dir = Arc::new(config.cache_dir);
    let tmdb_token = config.tmdb_api_token;
    let shutdown_flag = Arc::new(AtomicBool::new(false));

    // Start daemon with short interval and zero initial delay for testing
    let handle = ScanService::start_daemon(
        pool,
        media_roots,
        cache_dir,
        tmdb_token,
        Duration::from_millis(50),
        Duration::ZERO,
        shutdown_flag.clone(),
    );

    // Let it spin for a few ticks
    tokio::time::sleep(Duration::from_millis(120)).await;

    // Trigger shutdown
    shutdown_flag.store(true, Ordering::Relaxed);

    // Assert that the daemon loop terminates cleanly within 200ms
    let wait_res = tokio::time::timeout(Duration::from_millis(500), handle).await;
    assert!(
        wait_res.is_ok(),
        "ScanService daemon failed to terminate on shutdown signal"
    );
    assert!(
        wait_res.unwrap().is_ok(),
        "ScanService daemon task panicked"
    );

    // Allow in-flight scan to settle so subsequent tests don't see a busy scanner
    let _ = ScanService::wait_until_idle(Duration::from_millis(100)).await;
    ScanService::set_busy_for_test(false);
}

#[tokio::test]
async fn test_storage_service_daemon_lifecycle_and_shutdown() {
    let config = media_server_api::test_support::test_config().await;
    let pool = db::create_pool(&config.database_url)
        .await
        .expect("Failed to connect to test database");

    let media_roots = Arc::new(config.media_roots);
    let cache_dir = Arc::new(config.cache_dir);
    let shutdown_flag = Arc::new(AtomicBool::new(false));

    // Start storage daemon with short interval and zero initial delay
    let handle = StorageService::start_daemon(
        pool,
        media_roots,
        cache_dir,
        Duration::from_millis(50),
        Duration::ZERO,
        shutdown_flag.clone(),
    );

    // Let it spin
    tokio::time::sleep(Duration::from_millis(120)).await;

    // Trigger shutdown
    shutdown_flag.store(true, Ordering::Relaxed);

    // Assert that the daemon terminates cleanly
    let wait_res = tokio::time::timeout(Duration::from_millis(500), handle).await;
    assert!(
        wait_res.is_ok(),
        "StorageService daemon failed to terminate on shutdown signal"
    );
    assert!(
        wait_res.unwrap().is_ok(),
        "StorageService daemon task panicked"
    );
}
