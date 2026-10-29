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
    let mut tx = pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(7429184)")
        .execute(&mut *tx)
        .await?;

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
            priority          INTEGER     NOT NULL DEFAULT 0,
            created_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT transcode_jobs_filename_mode_key UNIQUE (filename, mode),
            CONSTRAINT transcode_jobs_status_check
                CHECK (status IN ('queued','running','completed','failed','canceled'))
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // Add priority column if table was previously created without it
    sqlx::query(
        r#"
        ALTER TABLE transcode_jobs ADD COLUMN IF NOT EXISTS priority INTEGER NOT NULL DEFAULT 0;
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // The claim path filters on (status, priority DESC, lease_expires_at, created_at);
    // without this the queue scan degrades to a sequential scan once the
    // table accumulates terminal rows.
    sqlx::query("DROP INDEX IF EXISTS transcode_jobs_claim_idx")
        .execute(&mut *tx)
        .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS transcode_jobs_claim_idx
            ON transcode_jobs (status, priority DESC, lease_expires_at, created_at)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // Auth & Identity Schema (Phase C5 Slice 4)
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS users (
            id BIGSERIAL PRIMARY KEY,
            google_sub TEXT NOT NULL UNIQUE,
            email TEXT NOT NULL,
            name TEXT,
            picture_url TEXT,
            role TEXT NOT NULL DEFAULT 'viewer',
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_login_at TIMESTAMPTZ
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // Retired 2026-10-23: the long-lived pairing-token table is gone. The
    // unconditional drop also heals a database restored from a pre-retirement
    // dump, which would otherwise bring the retired surface back. Do not
    // re-add `auth_tokens` without removing this drop. Rolling back to an
    // older binary re-creates an empty table, but the revoked rows are gone.
    sqlx::query("DROP TABLE IF EXISTS auth_tokens")
        .execute(&mut *tx)
        .await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS oauth_attempts (
            state TEXT PRIMARY KEY,
            nonce TEXT,
            verifier TEXT,
            redirect_uri TEXT,
            next_path TEXT,
            started_at BIGINT,
            used SMALLINT DEFAULT 0
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            user_id BIGINT REFERENCES users(id) ON DELETE CASCADE,
            email TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'viewer',
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            expires_at TIMESTAMPTZ NOT NULL
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // QR Device Pairing Sessions (remote login flow)
    // Each row represents a pending sign-in initiated by a TV/browser showing a QR code.
    // Expires after 2 minutes; confirmed=true once the phone completes the handshake.
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS device_pair_sessions (
            id          TEXT PRIMARY KEY,
            code_hash   TEXT NOT NULL,
            secret_hash TEXT,
            sig         TEXT NOT NULL,
            user_id     BIGINT REFERENCES users(id) ON DELETE CASCADE,
            session_id  TEXT,
            device_name TEXT,
            confirmed   BOOLEAN NOT NULL DEFAULT FALSE,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            expires_at  TIMESTAMPTZ NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '2 minutes')
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // Per-session secret binding for `GET /api/auth/qr/{id}/finalize`.
    //
    // That route hands out a session cookie, and `qr_id` alone appears in the
    // QR URL, the SSE URL, browser history and access logs - so it must not be
    // the only key. The waiting device receives a CSPRNG secret at creation
    // and stores it in a path-scoped cookie; only its SHA-256 is persisted.
    // Nullable because the column is added to an existing table: rows created
    // before this change fail closed in `finalize` (the table only holds
    // 2-minute sessions, so there is nothing to migrate).
    sqlx::query(
        r#"
        ALTER TABLE device_pair_sessions ADD COLUMN IF NOT EXISTS secret_hash TEXT;
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // The plaintext pair code is gone: `find_pair_session_by_code` and
    // `confirm_pair_session` compare against `code_hash` only, so there is
    // nothing left that needs to read the original. The drop also removes
    // `idx_device_pair_code`, which the next statement makes explicit for
    // databases that survived the column.
    sqlx::query(
        r#"
        ALTER TABLE device_pair_sessions DROP COLUMN IF EXISTS code;
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        DROP INDEX IF EXISTS idx_device_pair_code;
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_device_pair_expires ON device_pair_sessions(expires_at)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // Phase 5.3: QR Expiry & Finalize Status Race Condition
    sqlx::query(
        "ALTER TABLE device_pair_sessions ADD COLUMN IF NOT EXISTS finalized BOOLEAN NOT NULL DEFAULT FALSE",
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        "ALTER TABLE device_pair_sessions ADD COLUMN IF NOT EXISTS finalized_at TIMESTAMPTZ",
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_device_pair_sessions_lookup
            ON device_pair_sessions (id, expires_at, confirmed, finalized)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // `POST /api/auth/qr/lookup` resolves a pair code to a live session, so
    // the hash is read on every manual code entry. The table holds only
    // unexpired sessions, but the index is free and makes the lookup a
    // single index probe instead of a sequential scan.
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_device_pair_code_hash ON device_pair_sessions(code_hash)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // The library tables.
    //
    // These were created by the SQLite -> PostgreSQL migration script, not by
    // `ensure_schema`, which meant a fresh database was only half-formed: the
    // server booted, created its own tables, and then failed on the first
    // query that touched the catalog. The dedicated test database made that
    // visible immediately - the suite could not seed a single movie row.
    //
    // The DDL below matches the migrated production tables exactly, so
    // `CREATE TABLE IF NOT EXISTS` is a no-op against the live database.
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS movies (
            filename              TEXT PRIMARY KEY,
            title                 TEXT,
            year                  INTEGER,
            tmdb_id               INTEGER,
            overview              TEXT,
            poster_path           TEXT,
            backdrop_path         TEXT,
            runtime               INTEGER,
            genres                TEXT,
            vote_average          REAL,
            updated_at            BIGINT,
            release_date          TEXT,
            added_at              BIGINT,
            details_json          TEXT,
            last_metadata_refresh BIGINT
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_movies_tmdb
            ON movies (tmdb_id) WHERE tmdb_id IS NOT NULL
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS progress (
            id         BIGSERIAL PRIMARY KEY,
            user_id    BIGINT REFERENCES users(id) ON DELETE CASCADE,
            filename   TEXT        NOT NULL,
            "position" REAL        NOT NULL DEFAULT 0,
            duration   REAL        NOT NULL DEFAULT 0,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT uq_progress_user_filename UNIQUE NULLS NOT DISTINCT (user_id, filename)
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // Migrate existing single-user progress table to support per-user scoping
    sqlx::query(
        r#"
        ALTER TABLE progress
            ADD COLUMN IF NOT EXISTS id BIGSERIAL,
            ADD COLUMN IF NOT EXISTS user_id BIGINT REFERENCES users(id) ON DELETE CASCADE
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        DO $$
        BEGIN
            IF EXISTS (
                SELECT 1
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                  ON tc.constraint_name = kcu.constraint_name
                 AND tc.table_schema = kcu.table_schema
                WHERE tc.table_name = 'progress'
                  AND tc.constraint_type = 'PRIMARY KEY'
                  AND kcu.column_name = 'filename'
            ) THEN
                ALTER TABLE progress DROP CONSTRAINT progress_pkey;
                ALTER TABLE progress ADD CONSTRAINT progress_pkey PRIMARY KEY (id);
            END IF;
        END $$;
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE UNIQUE INDEX IF NOT EXISTS uq_progress_user_filename
            ON progress (user_id, filename) NULLS NOT DISTINCT
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_progress_updated
            ON progress (updated_at DESC)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_progress_user_updated
            ON progress (user_id, updated_at DESC)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS devices (
            device_id       TEXT PRIMARY KEY,
            custom_name     TEXT,
            device_name     TEXT,
            device_type     TEXT,
            device_os       TEXT,
            browser         TEXT,
            user_agent      TEXT,
            connection_type TEXT,
            client_ip       TEXT,
            public_ip       TEXT,
            mac_address     TEXT,
            isp             TEXT,
            city            TEXT,
            country         TEXT,
            first_seen      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_seen       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            device_model    TEXT
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_devices_last_seen
            ON devices (last_seen DESC)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    // Phase 2 (access control): a device belongs to the user who first
    // authenticated from it. The column is additive and nullable: NULL means
    // unowned (guests, and every row written before Phase 2), so this alters
    // an existing catalog without rewriting a single row.
    //
    // `ON DELETE SET NULL`, not CASCADE: deleting an account unlinks its
    // devices rather than deleting the physical client's row (and, through
    // the history FK, its watch history).
    sqlx::query(
        r#"
        ALTER TABLE devices
            ADD COLUMN IF NOT EXISTS user_id BIGINT REFERENCES users(id) ON DELETE SET NULL
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_devices_user
            ON devices (user_id)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS device_watch_history (
            id           BIGSERIAL PRIMARY KEY,
            device_id    TEXT        NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
            filename     TEXT        NOT NULL,
            "position"   REAL        NOT NULL DEFAULT 0,
            duration     REAL        NOT NULL DEFAULT 0,
            completed    SMALLINT    NOT NULL DEFAULT 0,
            last_watched TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT uq_device_watch_history UNIQUE (device_id, filename)
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_dwh_device
            ON device_watch_history (device_id, last_watched DESC)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS ip_cache (
            ip         TEXT PRIMARY KEY,
            isp        TEXT,
            org        TEXT,
            city       TEXT,
            country    TEXT,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS audit_logs (
            id          BIGSERIAL PRIMARY KEY,
            actor_type  TEXT        NOT NULL,
            actor_id    TEXT        NOT NULL,
            action      TEXT        NOT NULL,
            target_type TEXT,
            target_id   TEXT,
            details     JSONB,
            ip_address  TEXT,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at
            ON audit_logs (created_at DESC)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_audit_logs_action
            ON audit_logs (action)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_audit_logs_actor
            ON audit_logs (actor_type, actor_id)
        "#,
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;

    tracing::info!(
        "Rust schema ensured (transcode_jobs, users, sessions, \
         device_pair_sessions, movies, progress, devices, device_watch_history, ip_cache, audit_logs; \
         auth_tokens retired and dropped)"
    );
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
        .max_connections(50)
        .min_connections(8)
        .acquire_timeout(Duration::from_secs(30))
        .idle_timeout(Duration::from_secs(300))
        .connect(database_url)
        .await?;

    // Verify database connectivity
    sqlx::query("SELECT 1").execute(&pool).await?;

    ensure_schema(&pool).await?;

    tracing::info!("PostgreSQL connection pool initialized and verified successfully");
    Ok(pool)
}
