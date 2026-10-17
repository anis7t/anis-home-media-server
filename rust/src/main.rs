use media_server_api::{
    config::AppConfig, create_app_full, db, services::system_service::SystemService,
};
use std::net::SocketAddr;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize structured logging
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "media_server_api=info,tower_http=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    // Load configuration
    let config = AppConfig::from_env();
    tracing::info!(
        "Starting Anis' Home Media Server Rust API Foundation v{}",
        env!("CARGO_PKG_VERSION")
    );

    // Initialize database pool
    let pool = db::create_pool(&config.database_url).await?;

    // Phase 6A: Recover stale/interrupted jobs from previous runs (Option A)
    if let Err(e) = media_server_api::services::job_service::JobService::recover_stale_jobs(&pool).await {
        tracing::warn!("Failed to recover stale jobs on startup: {}", e);
    }

    // Phase 6A: Proactive library auto-transcoder daemon (5-minute interval)
    let sweeper_roots = std::sync::Arc::new(config.media_roots.clone());
    let sweeper_cache = std::sync::Arc::new(config.cache_dir.clone());
    media_server_api::services::transcode_sweeper::TranscodeSweeperService::start_daemon(
        pool.clone(),
        sweeper_roots.clone(),
        sweeper_cache.clone(),
        std::time::Duration::from_secs(300),
    );

    // Phase 6B: Native Multi-GPU Transcode Worker daemon
    let shutdown_flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let worker_id = format!("rust-worker-{}", std::process::id());
    media_server_api::services::transcode_worker::TranscodeWorker::start_worker(
        pool.clone(),
        sweeper_roots,
        sweeper_cache,
        worker_id,
        shutdown_flag.clone(),
    );

    // Initialize services
    let system_service = SystemService::new();

    // Build application router
    let app = create_app_full(
        pool,
        system_service,
        config.media_roots,
        config.cache_dir,
        Some(config.static_dir),
        Some(config.flask_origin),
    );

    let addr: SocketAddr = format!("{}:{}", config.host, config.port).parse()?;
    tracing::info!("Listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    // Connect info is required so device classification can tell a LAN
    // client from localhost, exactly as Flask's remote_addr does. Without it
    // every client would look like 127.0.0.1 and the dashboard's
    // connection_type would be wrong for every real device.
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await?;

    Ok(())
}

async fn shutdown_signal() {
    tokio::signal::ctrl_c()
        .await
        .expect("Failed to install Ctrl+C signal handler");
    tracing::info!("Shutting down Rust API gracefully...");
}
