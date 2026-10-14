use sqlx::postgres::{PgPool, PgPoolOptions};
use std::time::Duration;

pub async fn create_pool(database_url: &str) -> Result<PgPool, sqlx::Error> {
    let pool = PgPoolOptions::new()
        .max_connections(16)
        .min_connections(2)
        .acquire_timeout(Duration::from_secs(5))
        .idle_timeout(Duration::from_secs(300))
        .connect(database_url)
        .await?;

    // Verify database connectivity
    sqlx::query("SELECT 1")
        .execute(&pool)
        .await?;

    tracing::info!("PostgreSQL connection pool initialized and verified successfully");
    Ok(pool)
}
