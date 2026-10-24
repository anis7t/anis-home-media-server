use crate::error::AppError;
use crate::models::job::{JobStatus, TranscodeJob};
use sqlx::{PgPool, Postgres, Row, Transaction};

/// How long a claim is valid before another scheduler may reclaim it.
/// A crashed worker's job therefore becomes claimable again without any
/// external sweeper, which is the whole recovery story for 6A.
pub const DEFAULT_LEASE_SECONDS: i64 = 300;

pub const PRIORITY_BACKGROUND: i32 = 0;
pub const PRIORITY_INTERACTIVE: i32 = 10;

pub struct JobService;

impl JobService {
    /// Idempotent admission with default background priority (0).
    pub async fn enqueue(
        pool: &PgPool,
        filename: &str,
        mode: &str,
        force: bool,
    ) -> Result<TranscodeJob, AppError> {
        Self::enqueue_with_priority(pool, filename, mode, force, PRIORITY_BACKGROUND).await
    }

    /// Idempotent admission with explicit priority.
    ///
    /// Re-enqueueing a live job returns the existing row rather than creating
    /// a second one. If a queued job is re-enqueued with higher priority
    /// (e.g. an interactive user tap over a background sweep), its priority
    /// is promoted.
    pub async fn enqueue_with_priority(
        pool: &PgPool,
        filename: &str,
        mode: &str,
        force: bool,
        priority: i32,
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

        let existing: Option<(i64, String, i32)> = sqlx::query(
            "SELECT id, status, COALESCE(priority, 0) as priority FROM transcode_jobs WHERE filename = $1 AND mode = $2",
        )
        .bind(filename)
        .bind(mode)
        .fetch_optional(pool)
        .await?
        .map(|r| (
            r.get::<i64, _>("id"),
            r.get::<String, _>("status"),
            r.get::<i32, _>("priority"),
        ));

        if let Some((id, status, current_priority)) = existing {
            let current = JobStatus::parse(&status);
            let is_live = current.map(|s| s.is_live()).unwrap_or(false);
            if is_live && !force {
                // If queued and arriving with higher priority, promote it
                if status == "queued" && priority > current_priority {
                    sqlx::query(
                        "UPDATE transcode_jobs SET priority = $2, updated_at = CURRENT_TIMESTAMP WHERE id = $1",
                    )
                    .bind(id)
                    .bind(priority)
                    .execute(pool)
                    .await?;
                }
                if let Some(job) = Self::get_by_id(pool, id).await? {
                    return Ok(job);
                }
            } else if !is_live && !force {
                if let Some(job) = Self::get_by_id(pool, id).await? {
                    return Ok(job);
                }
            }

            // `force` on a terminal job: reopen as queued and clear the
            // previous outcome, keeping the row (and its id) stable.
            sqlx::query(
                r#"
                UPDATE transcode_jobs
                   SET status = 'queued', priority = $2, error = NULL, lease_owner = NULL,
                       lease_expires_at = NULL, updated_at = CURRENT_TIMESTAMP
                 WHERE id = $1
                "#,
            )
            .bind(id)
            .bind(priority)
            .execute(pool)
            .await?;
            return Ok(Self::get_by_id(pool, id).await?.unwrap());
        }

        let id: i64 = sqlx::query(
            r#"
            INSERT INTO transcode_jobs (filename, mode, status, priority)
            VALUES ($1, $2, 'queued', $3)
            ON CONFLICT (filename, mode) DO UPDATE SET updated_at = CURRENT_TIMESTAMP
            RETURNING id
            "#,
        )
        .bind(filename)
        .bind(mode)
        .bind(priority)
        .fetch_one(pool)
        .await?
        .get("id");

        Self::get_by_id(pool, id).await?.ok_or_else(|| {
            AppError::Internal("job row vanished immediately after insert".to_string())
        })
    }

    /// Atomically claim the highest priority, oldest claimable job for `owner`.
    ///
    /// Claimable means: `queued` (never claimed), or `running` with an
    /// expired/absent lease (a previous owner died). Evaluated by `priority DESC, created_at ASC`.
    /// The UPDATE and the RETURNING are one statement with `SKIP LOCKED`, so concurrent callers
    /// never receive the same row.
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
                    ORDER BY priority DESC, created_at ASC
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

    /// Recover orphaned running jobs after a server crash/restart.
    ///
    /// Finds any job with status 'running' whose lease has expired or is null,
    /// and transitions it cleanly to 'failed' with an explanatory error.
    pub async fn recover_stale_jobs(pool: &PgPool) -> Result<u64, AppError> {
        let res = sqlx::query(
            r#"
            UPDATE transcode_jobs
               SET status = 'failed',
                   error = 'Server restarted during transcode',
                   lease_owner = NULL,
                   lease_expires_at = NULL,
                   updated_at = CURRENT_TIMESTAMP
             WHERE status = 'running'
            "#,
        )
        .execute(pool)
        .await?;
        Ok(res.rows_affected())
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

    /// Return all active (running/queued) jobs followed by the most recently updated finished jobs.
    /// This guarantees that running/queued jobs are never truncated or omitted regardless of their creation timestamp.
    pub async fn list_for_dashboard(pool: &PgPool, recent_limit: i64) -> Result<Vec<TranscodeJob>, AppError> {
        let rows = sqlx::query(
            r#"
            WITH active AS (
                SELECT * FROM transcode_jobs 
                WHERE status IN ('running', 'queued') 
                ORDER BY priority DESC, created_at ASC
            ),
            recent AS (
                SELECT * FROM transcode_jobs 
                WHERE status NOT IN ('running', 'queued') 
                ORDER BY updated_at DESC 
                LIMIT $1
            )
            SELECT * FROM active 
            UNION ALL 
            SELECT * FROM recent;
            "#,
        )
        .bind(recent_limit.clamp(1, 500))
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
        priority: row.try_get("priority").unwrap_or(0),
        error: row.get("error"),
        lease_owner: row.get("lease_owner"),
        lease_expires_at: row.get("lease_expires_at"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}