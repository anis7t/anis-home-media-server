use media_server_api::{
    config::AppConfig,
    db,
    services::scan_service::ScanService,
    services::storage_service::StorageService,
};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

#[tokio::test]
async fn test_scan_service_daemon_lifecycle_and_shutdown() {
    let base_dir = Arc::new(PathBuf::from("E:\\MediaServer"));
    let shutdown_flag = Arc::new(AtomicBool::new(false));

    // Start daemon with short interval and zero initial delay for testing
    let handle = ScanService::start_daemon(
        base_dir,
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
    assert!(wait_res.is_ok(), "ScanService daemon failed to terminate on shutdown signal");
    assert!(wait_res.unwrap().is_ok(), "ScanService daemon task panicked");
}

#[tokio::test]
async fn test_storage_service_daemon_lifecycle_and_shutdown() {
    let config = AppConfig::from_env();
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
    assert!(wait_res.is_ok(), "StorageService daemon failed to terminate on shutdown signal");
    assert!(wait_res.unwrap().is_ok(), "StorageService daemon task panicked");
}
