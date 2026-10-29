use crate::error::AppError;
use crate::services::hls_service::HlsService;
use crate::services::job_service::JobService;
use crate::services::path_resolver::PathResolver;
use crate::services::probe_service::cached_probe;
use sqlx::{PgPool, Row};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tracing::{debug, error, info, warn};

/// Minimum free space required on cache drive (15 GB).
const MIN_DISK_HEADROOM_BYTES: u64 = 15 * 1024 * 1024 * 1024;

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

    /// Check if the disk holding `cache_dir` has sufficient free space.
    pub fn check_disk_healthy(cache_dir: &Path) -> bool {
        let disks = sysinfo::Disks::new_with_refreshed_list();
        let cache_str = cache_dir.to_string_lossy().to_uppercase();

        for disk in &disks {
            let mount = disk.mount_point().to_string_lossy().to_uppercase();
            if !mount.is_empty() && cache_str.starts_with(&mount) {
                let avail = disk.available_space();
                if avail < MIN_DISK_HEADROOM_BYTES {
                    warn!(
                        "TranscodeSweeper: Disk {} free space ({:.1} GB) is below safety floor (15 GB). Pausing queue additions.",
                        mount,
                        avail as f64 / (1024.0 * 1024.0 * 1024.0)
                    );
                    return false;
                }
                return true;
            }
        }
        true
    }

    /// Assign wave priorities:
    /// - Priority 10: HD Baseline (1080p, 720p)
    /// - Priority 5: Mobile / Bandwidth (480p, 360p)
    /// - Priority 1: 4K Ultra HD (2160p, 1440p)
    pub fn priority_for_quality(label: &str) -> i32 {
        match label {
            "1080p" | "720p" => 10,
            "480p" | "360p" => 5,
            "2160p" | "1440p" => 1,
            _ => 5,
        }
    }

    /// Single pass over movies in PostgreSQL evaluating all applicable quality tiers.
    pub async fn sweep_once(
        pool: &PgPool,
        roots: &[PathBuf],
        cache_dir: &Path,
    ) -> Result<SweeperStats, AppError> {
        let mut stats = SweeperStats::default();

        if !Self::check_disk_healthy(cache_dir) {
            info!("Transcode sweep skipped due to disk safety floor.");
            return Ok(stats);
        }

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

            // Probe video stream dimensions
            let probe = cached_probe(&video_path).await;
            let v_stream = probe.first_stream("video");
            let source_w = v_stream.and_then(|v| v.width).unwrap_or(0) as u32;
            let source_h = v_stream.and_then(|v| v.height).unwrap_or(0) as u32;

            if source_w == 0 || source_h == 0 {
                stats.skipped += 1;
                continue;
            }

            let rel_key = crate::routes::transcode::video_path_key(&video_path, roots);
            let mut seen_heights = HashSet::new();

            // Iterate standard quality tiers
            for &(label, tier_w, tier_h, _, _) in HlsService::STANDARD_QUALITIES {
                // Disk check before each job
                if !Self::check_disk_healthy(cache_dir) {
                    info!("Transcode sweep stopping early: reached disk safety floor.");
                    return Ok(stats);
                }

                // Check applicability (with widescreen support without upscaling)
                let is_applicable = if tier_h <= source_h {
                    true
                } else if source_w >= tier_w.saturating_sub(32)
                    && (source_h as u64 * 2 >= tier_h as u64)
                {
                    true
                } else {
                    false
                };

                if !is_applicable {
                    continue;
                }

                let effective_h = tier_h.min(source_h);
                if !seen_heights.insert(effective_h) {
                    continue;
                }

                // Check if already 100% complete on disk with #EXT-X-ENDLIST
                let q_dir =
                    HlsService::find_hls_quality_dir(&video_path, roots, cache_dir, Some(label));
                let q_pl = q_dir.join("playlist.m3u8");
                if q_pl.is_file() {
                    if let Ok(content) = std::fs::read_to_string(&q_pl) {
                        if content.contains("#EXT-X-ENDLIST") {
                            stats.skipped += 1;
                            continue;
                        }
                    }
                }

                let mode = format!("hls:{}", label);
                let priority = Self::priority_for_quality(label);

                match JobService::get_by_filename(pool, &rel_key, &mode).await {
                    Ok(Some(existing)) => {
                        if existing.status == "queued" || existing.status == "running" {
                            stats.skipped += 1;
                            continue;
                        }
                        if existing.status == "completed" {
                            stats.skipped += 1;
                            continue;
                        }
                        if existing.status == "canceled" {
                            stats.skipped += 1;
                            continue;
                        }
                        // Circuit breaker: do not endlessly re-enqueue jobs that repeatedly failed
                        if existing.status == "failed" && existing.attempts >= 3 {
                            debug!(
                                "Sweeper skipping failed job for {} ({}): exceeded max attempts ({})",
                                rel_key, mode, existing.attempts
                            );
                            stats.skipped += 1;
                            continue;
                        }
                        // Reopen failed or stale job with force=true
                        if let Err(e) =
                            JobService::enqueue_with_priority(pool, &rel_key, &mode, true, priority)
                                .await
                        {
                            warn!(
                                "Failed to re-enqueue transcode for {} ({}): {}",
                                rel_key, mode, e
                            );
                            stats.errors += 1;
                        } else {
                            stats.queued += 1;
                        }
                    }
                    Ok(None) => {
                        if let Err(e) = JobService::enqueue_with_priority(
                            pool, &rel_key, &mode, false, priority,
                        )
                        .await
                        {
                            warn!(
                                "Failed to enqueue transcode for {} ({}): {}",
                                rel_key, mode, e
                            );
                            stats.errors += 1;
                        } else {
                            stats.queued += 1;
                        }
                    }
                    Err(e) => {
                        warn!(
                            "Database error checking job for {} ({}): {}",
                            rel_key, mode, e
                        );
                        stats.errors += 1;
                    }
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
            info!(
                "Transcode sweeper daemon started (interval: {:?})",
                interval
            );
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
