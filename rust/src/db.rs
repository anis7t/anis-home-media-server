use sqlx::postgres::{PgPool, PgPoolOptions};
use std::time::Duration;

/// Idempotent DDL for Rust-owned tables.
///
/// The crate has no migration runner yet (Python owns `POSTGRES_MIGRATIONS`),
/// so schema is applied at pool creation with IF NOT EXISTS. That is safe to
/// run on every boot and against the live database; it never drops or
/// rewrites an existing object. Kept as a function so a later runner can
/// replace the call site without touching callers.
pub async fn ensure_schema(pool: &PgPool) -> Result<(), sqlx::Error> {
    // Phase 6A: durable transcode job records and single-scheduler ownership.
    // `unique (filename, mode)` is what makes enqueue idempotent, and
    // `lease_owner`/`lease_expires_at` are what make ownership exclusive.
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS transcode_jobs (
            id                BIGSERIAL PRIMARY KEY,
            filename          TEXT        NOT NULL,
            mode              TEXT        NOT NULL DEFAULT 'hls',
            status            TEXT        NOT NULL DEFAULT 'queued',
            progress          DOUBLE PRECISION,
            speed             DOUBLE PRECISION,
            fps               DOUBLE PRECISION,
            eta               DOUBLE PRECISION,
            resume_time       DOUBLE PRECISION,
            start_seg         INTEGER,
            attempts          INTEGER     NOT NULL DEFAULT 0,
            error             TEXT,
            lease_owner       TEXT,
            lease_expires_at  TIMESTAMPTZ,
            created_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT transcode_jobs_filename_mode_key UNIQUE (filename, mode),
            CONSTRAINT transcode_jobs_status_check
                CHECK (status IN ('queued','running','completed','failed','canceled'))
        )
        "#,
    )
    .execute(pool)
    .await?;

    // The claim path filters on (status, lease_expires_at, created_at);
    // without this the queue scan degrades to a sequential scan once the
    // table accumulates terminal rows.
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS transcode_jobs_claim_idx
            ON transcode_jobs (status, lease_expires_at, created_at)
        "#,
    )
    .execute(pool)
    .await?;

    tracing::info!("Rust schema ensured (transcode_jobs)");
    Ok(())
}

/// Pool for integration tests.
///
/// Deliberately different from production: a small max with a generous
/// acquire timeout. The production pool (16 connections, 5 s acquire)
/// surfaced as flaky `PoolTimedOut` panics when a test suite opened pools
/// concurrently against a PostgreSQL that had plenty of headroom - the
/// failure was pool-local pressure, not server exhaustion. A test pool
/// should wait rather than fail, because a timed-out acquire says nothing
/// about the behaviour under test.
pub async fn create_test_pool(database_url: &str) -> Result<PgPool, sqlx::Error> {
    let pool = PgPoolOptions::new()
        .max_connections(4)
        .min_connections(1)
        .acquire_timeout(Duration::from_secs(30))
        .idle_timeout(Duration::from_secs(60))
        .connect(database_url)
        .await?;

    sqlx::query("SELECT 1").execute(&pool).await?;
    ensure_schema(&pool).await?;
    Ok(pool)
}

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

    ensure_schema(&pool).await?;

    tracing::info!("PostgreSQL connection pool initialized and verified successfully");
    Ok(pool)
}
