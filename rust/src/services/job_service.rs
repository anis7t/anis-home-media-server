use crate::error::AppError;
use crate::models::job::{JobStatus, TranscodeJob};
use sqlx::{PgPool, Postgres, Row, Transaction};

/// How long a claim is valid before another scheduler may reclaim it.
/// A crashed worker's job therefore becomes claimable again without any
/// external sweeper, which is the whole recovery story for 6A.
pub const DEFAULT_LEASE_SECONDS: i64 = 300;

pub struct JobService;

impl JobService {
    /// Idempotent admission. Re-enqueueing a live job returns the existing
    /// row rather than creating a second one - the unique constraint on
    /// (filename, mode) is what makes that safe under concurrency, not this
    /// read-then-write sequence.
    ///
    /// A terminal job is only re-opened when `force` is set, mirroring
    /// Flask's `ensure_hls_transcode(force=True)`, which exists solely for
    /// a measured frame deficit. Without `force`, a `completed` job stays
    /// completed and a `failed` job stays failed until a caller retries.
    pub async fn enqueue(
        pool: &PgPool,
        filename: &str,
        mode: &str,
        force: bool,
    ) -> Result<TranscodeJob, AppError> {
        let filename = filename.trim();
        if filename.is_empty() {
            return Err(AppError::BadRequest("Filename is required".to_string()));
        }
        if filename.contains("..") {
            return Err(AppError::BadRequest(
                "Filename must not contain path traversal".to_string(),
            ));
        }

        let existing: Option<(i64, String)> = sqlx::query(
            "SELECT id, status FROM transcode_jobs WHERE filename = $1 AND mode = $2",
        )
        .bind(filename)
        .bind(mode)
        .fetch_optional(pool)
        .await?
        .map(|r| (r.get::<i64, _>("id"), r.get::<String, _>("status")));

        if let Some((id, status)) = existing {
            let current = JobStatus::parse(&status);
            let is_live = current.map(|s| s.is_live()).unwrap_or(false);
            if is_live || !force {
                if let Some(job) = Self::get_by_id(pool, id).await? {
                    return Ok(job);
                }
            }
            // `force` on a terminal job: reopen as queued and clear the
            // previous outcome, keeping the row (and its id) stable.
            sqlx::query(
                r#"
                UPDATE transcode_jobs
                   SET status = 'queued', error = NULL, lease_owner = NULL,
                       lease_expires_at = NULL, updated_at = CURRENT_TIMESTAMP
                 WHERE id = $1
                "#,
            )
            .bind(id)
            .execute(pool)
            .await?;
            return Ok(Self::get_by_id(pool, id).await?.unwrap());
        }

        let id: i64 = sqlx::query(
            r#"
            INSERT INTO transcode_jobs (filename, mode, status)
            VALUES ($1, $2, 'queued')
            ON CONFLICT (filename, mode) DO UPDATE SET updated_at = CURRENT_TIMESTAMP
            RETURNING id
            "#,
        )
        .bind(filename)
        .bind(mode)
        .fetch_one(pool)
        .await?
        .get("id");

        Self::get_by_id(pool, id).await?.ok_or_else(|| {
            AppError::Internal("job row vanished immediately after insert".to_string())
        })
    }

    /// Atomically claim the oldest claimable job for `owner`.
    ///
    /// Claimable means: `queued` (never claimed), or `running` with an
    /// expired/absent lease (a previous owner died). The UPDATE and the
    /// RETURNING are one statement, so two concurrent callers can never
    /// receive the same row - this is the single-scheduler guarantee.
    pub async fn claim_next(
        pool: &PgPool,
        owner: &str,
        lease_seconds: i64,
    ) -> Result<Option<TranscodeJob>, AppError> {
        let mut tx: Transaction<'_, Postgres> = pool.begin().await?;

        let id: Option<i64> = sqlx::query(
            r#"
            UPDATE transcode_jobs
               SET status = 'running',
                   lease_owner = $1,
                   lease_expires_at = CURRENT_TIMESTAMP
                       + ($2 || ' seconds')::interval,
                   attempts = attempts + 1,
                   updated_at = CURRENT_TIMESTAMP
             WHERE id = (
                   SELECT id FROM transcode_jobs
                    WHERE status = 'queued'
                       OR (status = 'running'
                           AND (lease_expires_at IS NULL
                                OR lease_expires_at < CURRENT_TIMESTAMP))
                    ORDER BY created_at ASC
                    FOR UPDATE SKIP LOCKED
                    LIMIT 1
             )
            RETURNING id
            "#,
        )
        .bind(owner)
        .bind(lease_seconds.to_string())
        .fetch_optional(&mut *tx)
        .await?
        .map(|r| r.get::<i64, _>("id"));

        let job = match id {
            Some(id) => Self::get_by_id_tx(&mut tx, id).await?,
            None => None,
        };

        tx.commit().await?;
        Ok(job)
    }

    /// Extend the lease of a job this caller still owns. Returns false if
    /// the row is no longer owned by `owner` (it was reclaimed), so a
    /// worker that lost its lease stops instead of writing over the new
    /// owner's progress.
    pub async fn renew_lease(
        pool: &PgPool,
        id: i64,
        owner: &str,
        lease_seconds: i64,
    ) -> Result<bool, AppError> {
        let res = sqlx::query(
            r#"
            UPDATE transcode_jobs
               SET lease_expires_at = CURRENT_TIMESTAMP + ($3 || ' seconds')::interval,
                   updated_at = CURRENT_TIMESTAMP
             WHERE id = $1 AND lease_owner = $2
            "#,
        )
        .bind(id)
        .bind(owner)
        .bind(lease_seconds.to_string())
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    /// Record progress for a running job owned by `owner`.
    pub async fn update_progress(
        pool: &PgPool,
        id: i64,
        owner: &str,
        progress: Option<f64>,
        speed: Option<f64>,
        fps: Option<f64>,
        eta: Option<f64>,
    ) -> Result<bool, AppError> {
        let res = sqlx::query(
            r#"
            UPDATE transcode_jobs
               SET progress = $3, speed = $4, fps = $5, eta = $6,
                   updated_at = CURRENT_TIMESTAMP
             WHERE id = $1 AND lease_owner = $2 AND status = 'running'
            "#,
        )
        .bind(id)
        .bind(owner)
        .bind(progress)
        .bind(speed)
        .bind(fps)
        .bind(eta)
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn complete(
        pool: &PgPool,
        id: i64,
        owner: &str,
    ) -> Result<bool, AppError> {
        let res = sqlx::query(
            r#"
            UPDATE transcode_jobs
               SET status = 'completed', progress = 100.0, eta = 0.0,
                   error = NULL, lease_owner = NULL, lease_expires_at = NULL,
                   updated_at = CURRENT_TIMESTAMP
             WHERE id = $1 AND lease_owner = $2
            "#,
        )
        .bind(id)
        .bind(owner)
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn fail(pool: &PgPool, id: i64, owner: &str, error: &str) -> Result<bool, AppError> {
        let res = sqlx::query(
            r#"
            UPDATE transcode_jobs
               SET status = 'failed', error = $3, lease_owner = NULL,
                   lease_expires_at = NULL, updated_at = CURRENT_TIMESTAMP
             WHERE id = $1 AND lease_owner = $2
            "#,
        )
        .bind(id)
        .bind(owner)
        .bind(error)
        .execute(pool)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    /// Cancel a job. A queued job is canceled directly; a running job is
    /// only canceled by its current lease owner, so a cancel cannot race a
    /// legitimate worker into a state neither side intended.
    pub async fn cancel(pool: &PgPool, id: i64, owner: Option<&str>) -> Result<bool, AppError> {
        let res = match owner {
            Some(o) => {
                sqlx::query(
                    r#"
                    UPDATE transcode_jobs
                       SET status = 'canceled', lease_owner = NULL,
                           lease_expires_at = NULL, updated_at = CURRENT_TIMESTAMP
                     WHERE id = $1
                       AND (status = 'queued' OR (status = 'running' AND lease_owner = $2))
                    "#,
                )
                .bind(id)
                .bind(o)
                .execute(pool)
                .await?
            }
            None => {
                sqlx::query(
                    r#"
                    UPDATE transcode_jobs
                       SET status = 'canceled', lease_owner = NULL,
                           lease_expires_at = NULL, updated_at = CURRENT_TIMESTAMP
                     WHERE id = $1 AND status = 'queued'
                    "#,
                )
                .bind(id)
                .execute(pool)
                .await?
            }
        };
        Ok(res.rows_affected() > 0)
    }

    pub async fn get_by_filename(
        pool: &PgPool,
        filename: &str,
        mode: &str,
    ) -> Result<Option<TranscodeJob>, AppError> {
        let row = sqlx::query(
            "SELECT * FROM transcode_jobs WHERE filename = $1 AND mode = $2",
        )
        .bind(filename.trim())
        .bind(mode)
        .fetch_optional(pool)
        .await?;
        Ok(row.map(|r| map_job(&r)))
    }

    pub async fn get_by_id(pool: &PgPool, id: i64) -> Result<Option<TranscodeJob>, AppError> {
        let row = sqlx::query("SELECT * FROM transcode_jobs WHERE id = $1")
            .bind(id)
            .fetch_optional(pool)
            .await?;
        Ok(row.map(|r| map_job(&r)))
    }

    async fn get_by_id_tx(
        tx: &mut Transaction<'_, Postgres>,
        id: i64,
    ) -> Result<Option<TranscodeJob>, AppError> {
        let row = sqlx::query("SELECT * FROM transcode_jobs WHERE id = $1")
            .bind(id)
            .fetch_optional(&mut **tx)
            .await?;
        Ok(row.map(|r| map_job(&r)))
    }

    pub async fn list(pool: &PgPool, limit: i64) -> Result<Vec<TranscodeJob>, AppError> {
        let rows = sqlx::query(
            "SELECT * FROM transcode_jobs ORDER BY created_at DESC LIMIT $1",
        )
        .bind(limit.clamp(1, 500))
        .fetch_all(pool)
        .await?;
        Ok(rows.iter().map(map_job).collect())
    }
}

fn map_job(row: &sqlx::postgres::PgRow) -> TranscodeJob {
    TranscodeJob {
        id: row.get("id"),
        filename: row.get("filename"),
        mode: row.get("mode"),
        status: row.get("status"),
        progress: row.get("progress"),
        speed: row.get("speed"),
        fps: row.get("fps"),
        eta: row.get("eta"),
        resume_time: row.get("resume_time"),
        start_seg: row.get("start_seg"),
        attempts: row.get("attempts"),
        error: row.get("error"),
        lease_owner: row.get("lease_owner"),
        lease_expires_at: row.get("lease_expires_at"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}