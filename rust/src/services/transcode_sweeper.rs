use crate::error::AppError;
use crate::services::hls_service::HlsService;
use crate::services::job_service::{JobService, PRIORITY_BACKGROUND};
use crate::services::path_resolver::PathResolver;
use sqlx::{PgPool, Row};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tracing::{error, info, warn};

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct SweeperStats {
    pub scanned: u64,
    pub queued: u64,
    pub skipped: u64,
    pub errors: u64,
}

pub struct TranscodeSweeperService;

impl TranscodeSweeperService {
    /// Helper to test if a given media file needs transcoding based on its extension
    pub fn file_needs_transcode(path: &Path) -> bool {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();
        match ext.as_str() {
            "mkv" | "avi" | "flv" | "wmv" | "ts" | "m2ts" => true,
            "mp4" | "m4v" | "mov" | "webm" => false,
            _ => true,
        }
    }

    /// Single pass over movies in PostgreSQL.
    pub async fn sweep_once(
        pool: &PgPool,
        roots: &[PathBuf],
        cache_dir: &Path,
    ) -> Result<SweeperStats, AppError> {
        let mut stats = SweeperStats::default();

        // 1. Fetch all distinct filenames in the library
        let rows = sqlx::query("SELECT DISTINCT filename FROM movies")
            .fetch_all(pool)
            .await?;

        for r in rows {
            stats.scanned += 1;
            let filename: String = r.get("filename");

            // Resolve the media path
            let video_path = match PathResolver::resolve_media_path(&filename, roots) {
                Ok(p) => p,
                Err(_) => {
                    stats.errors += 1;
                    continue;
                }
            };

            // Does it need transcode?
            if !Self::file_needs_transcode(&video_path) {
                stats.skipped += 1;
                continue;
            }

            // Is HLS transcode already 100% complete across root or quality tiers?
            let hls_dir = HlsService::find_hls_dir(&video_path, roots, cache_dir);
            if HlsService::is_hls_complete(&hls_dir) {
                stats.skipped += 1;
                continue;
            }

            // Check if already queued or running
            let rel_key = crate::routes::transcode::video_path_key(&video_path, roots);
            match JobService::get_by_filename(pool, &rel_key, "hls").await {
                Ok(Some(existing)) => {
                    if existing.status == "queued" || existing.status == "running" {
                        stats.skipped += 1;
                        continue;
                    }
                    if existing.status == "completed" {
                        stats.skipped += 1;
                        continue;
                    }
                    // If failed/canceled, re-enqueue
                    if let Err(e) = JobService::enqueue_with_priority(pool, &rel_key, "hls", true, PRIORITY_BACKGROUND).await {
                        warn!("Failed to re-enqueue transcode for {}: {}", rel_key, e);
                        stats.errors += 1;
                    } else {
                        stats.queued += 1;
                    }
                }
                Ok(None) => {
                    // Not in queue at all: enqueue
                    if let Err(e) = JobService::enqueue_with_priority(pool, &rel_key, "hls", false, PRIORITY_BACKGROUND).await {
                        warn!("Failed to enqueue transcode for {}: {}", rel_key, e);
                        stats.errors += 1;
                    } else {
                        stats.queued += 1;
                    }
                }
                Err(e) => {
                    warn!("Database error checking job for {}: {}", rel_key, e);
                    stats.errors += 1;
                }
            }
        }

        info!(
            "Transcode sweep completed: scanned={}, queued={}, skipped={}, errors={}",
            stats.scanned, stats.queued, stats.skipped, stats.errors
        );

        Ok(stats)
    }

    /// Spawns background sweeper daemon running periodically.
    pub fn start_daemon(
        pool: PgPool,
        roots: Arc<Vec<PathBuf>>,
        cache_dir: Arc<PathBuf>,
        interval: Duration,
    ) {
        tokio::spawn(async move {
            info!("Transcode sweeper daemon started (interval: {:?})", interval);
            // Initial delay before first sweep to let server boot cleanly
            tokio::time::sleep(Duration::from_secs(10)).await;

            loop {
                if let Err(e) = Self::sweep_once(&pool, &roots, &cache_dir).await {
                    error!("Transcode sweeper loop encountered error: {}", e);
                }
                tokio::time::sleep(interval).await;
            }
        });
    }
}
