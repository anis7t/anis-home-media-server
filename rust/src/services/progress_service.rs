use crate::error::AppError;
use crate::models::progress::{ProgressResponse, UpdateProgressRequest};
use sqlx::{PgPool, Row};

pub struct ProgressService;

impl ProgressService {
    /// Retrieve playback watch progress for a given filename and optional device ID.
    pub async fn get_progress(
        pool: &PgPool,
        filename: &str,
        device_id: Option<&str>,
    ) -> Result<ProgressResponse, AppError> {
        let trimmed_filename = filename.trim();
        if trimmed_filename.is_empty() {
            return Err(AppError::BadRequest("Filename is required".to_string()));
        }

        // 1. If device_id is present, query device_watch_history.
        // If no record exists for this device, return 0.0 (do not leak another device's progress).
        if let Some(dev) = device_id.filter(|d| !d.trim().is_empty()) {
            let row = sqlx::query(
                r#"
                SELECT
                    position::double precision as position,
                    duration::double precision as duration
                FROM device_watch_history
                WHERE device_id = $1 AND filename = $2
                "#,
            )
            .bind(dev)
            .bind(trimmed_filename)
            .fetch_optional(pool)
            .await?;

            if let Some(r) = row {
                let position: f64 = r
                    .try_get::<f64, _>("position")
                    .or_else(|_| r.try_get::<f32, _>("position").map(|v| v as f64))
                    .unwrap_or(0.0);
                let duration: f64 = r
                    .try_get::<f64, _>("duration")
                    .or_else(|_| r.try_get::<f32, _>("duration").map(|v| v as f64))
                    .unwrap_or(0.0);
                return Ok(ProgressResponse { position, duration });
            } else {
                return Ok(ProgressResponse {
                    position: 0.0,
                    duration: 0.0,
                });
            }
        }

        // 2. Only if no device_id was provided, fallback to global progress table
        let row = sqlx::query(
            r#"
            SELECT
                position::double precision as position,
                duration::double precision as duration
            FROM progress
            WHERE filename = $1
            "#,
        )
        .bind(trimmed_filename)
        .fetch_optional(pool)
        .await?;

        if let Some(r) = row {
            let position: f64 = r
                .try_get::<f64, _>("position")
                .or_else(|_| r.try_get::<f32, _>("position").map(|v| v as f64))
                .unwrap_or(0.0);
            let duration: f64 = r
                .try_get::<f64, _>("duration")
                .or_else(|_| r.try_get::<f32, _>("duration").map(|v| v as f64))
                .unwrap_or(0.0);
            return Ok(ProgressResponse { position, duration });
        }

        // 3. Default to 0.0 if not found
        Ok(ProgressResponse {
            position: 0.0,
            duration: 0.0,
        })
    }

    /// Persist watch progress to both `progress` and `device_watch_history`.
    pub async fn update_progress(
        pool: &PgPool,
        req: UpdateProgressRequest,
        header_device_id: Option<&str>,
    ) -> Result<(), AppError> {
        let filename = req.filename.trim();
        if filename.is_empty() {
            return Err(AppError::BadRequest("Filename is required".to_string()));
        }

        let dur = req.duration.max(0.0);
        let mut pos = req.position.max(0.0);
        if dur > 0.0 {
            pos = pos.min(dur);
        }

        // Upsert into global progress table
        sqlx::query(
            r#"
            INSERT INTO progress (filename, position, duration, updated_at)
            VALUES ($1, $2::real, $3::real, CURRENT_TIMESTAMP)
            ON CONFLICT (filename) DO UPDATE SET
                position = EXCLUDED.position,
                duration = EXCLUDED.duration,
                updated_at = CURRENT_TIMESTAMP
            "#,
        )
        .bind(filename)
        .bind(pos)
        .bind(dur)
        .execute(pool)
        .await?;

        // Determine effective device ID (payload device_id takes precedence over header)
        let effective_device_id = req
            .device_id
            .as_deref()
            .or(header_device_id)
            .filter(|d| !d.trim().is_empty());

        if let Some(dev) = effective_device_id {
            // Ensure device exists in devices table to satisfy FK constraint
            sqlx::query(
                r#"
                INSERT INTO devices (device_id, device_name, device_type, first_seen, last_seen)
                VALUES ($1, 'Client Device', 'Device', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                ON CONFLICT (device_id) DO UPDATE SET last_seen = CURRENT_TIMESTAMP
                "#,
            )
            .bind(dev)
            .execute(pool)
            .await?;

            let completed = if dur > 0.0 && (pos >= dur * 0.9 || (dur - pos) <= 15.0) {
                1i16
            } else {
                0i16
            };

            sqlx::query(
                r#"
                INSERT INTO device_watch_history (
                    device_id, filename, position, duration, completed, last_watched
                ) VALUES ($1, $2, $3::real, $4::real, $5, CURRENT_TIMESTAMP)
                ON CONFLICT (device_id, filename) DO UPDATE SET
                    position = EXCLUDED.position,
                    duration = EXCLUDED.duration,
                    completed = EXCLUDED.completed,
                    last_watched = CURRENT_TIMESTAMP
                "#,
            )
            .bind(dev)
            .bind(filename)
            .bind(pos)
            .bind(dur)
            .bind(completed)
            .execute(pool)
            .await?;
        }

        Ok(())
    }
}
