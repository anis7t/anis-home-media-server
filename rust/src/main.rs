use media_server_api::{config::AppConfig, create_app, db, services::system_service::SystemService};
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
    let app = create_app(pool, system_service);

    let addr: SocketAddr = format!("{}:{}", config.host, config.port).parse()?;
    tracing::info!("Listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app)
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
