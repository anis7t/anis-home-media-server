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
