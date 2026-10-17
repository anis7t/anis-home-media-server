use crate::error::AppError;
use crate::models::storage::{
    ArchiveResult, CacheAuditData, CacheAuditItem, PurgeResult, StorageAuditResponse,
    StorageSettingsResponse,
};
use crate::services::hls_service::HlsService;
use crate::services::path_resolver::PathResolver;
use crate::services::preview_service::PreviewService;
use crate::services::scan_service::ScanService;
use crate::services::system_service::SystemService;
use sqlx::PgPool;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tracing::{info, warn};

pub const ALLOWED_RETENTION_POLICIES: &[&str] = &["archive", "keep", "purge_cache"];
pub const DEFAULT_RETENTION_POLICY: &str = "keep";
pub const RECENT_CACHE_GRACE_SECONDS: f64 = 600.0;

pub struct StorageService;

impl StorageService {
    /// Read current storage settings from PostgreSQL `settings` table.
    pub async fn get_settings(
        pool: &PgPool,
        media_roots: &[PathBuf],
    ) -> StorageSettingsResponse {
        let policy: Option<String> =
            sqlx::query_scalar("SELECT value FROM settings WHERE key = 'retention_policy'")
                .fetch_optional(pool)
                .await
                .unwrap_or(None);

        let retention_policy = policy.unwrap_or_else(|| DEFAULT_RETENTION_POLICY.to_string());

        let archive_dir = std::env::var("MEDIA_SERVER_ARCHIVE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                media_roots
                    .first()
                    .map(|r| r.join(".archive"))
                    .unwrap_or_else(|| PathBuf::from("D:\\Flicks\\.archive"))
            });

        StorageSettingsResponse {
            retention_policy,
            allowed_policies: ALLOWED_RETENTION_POLICIES
                .iter()
                .map(|s| s.to_string())
                .collect(),
            archive_dir: archive_dir.to_string_lossy().to_string(),
        }
    }

    /// Update storage retention policy in PostgreSQL `settings` table.
    pub async fn set_settings(pool: &PgPool, policy: &str) -> Result<String, AppError> {
        let clean = policy.trim().to_lowercase();
        if !ALLOWED_RETENTION_POLICIES.contains(&clean.as_str()) {
            return Err(AppError::BadRequest(format!(
                "Invalid retention policy. Allowed: {:?}",
                ALLOWED_RETENTION_POLICIES
            )));
        }

        sqlx::query(
            r#"
            INSERT INTO settings (key, value)
            VALUES ('retention_policy', $1)
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
            "#,
        )
        .bind(&clean)
        .execute(pool)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to persist retention policy: {}", e)))?;

        info!("Storage retention policy updated to '{}'", clean);
        Ok(clean)
    }

    /// Comprehensive cache audit of HLS and Preview cache directories.
    pub async fn audit_caches(
        pool: &PgPool,
        media_roots: &[PathBuf],
        cache_dir: &Path,
        system_service: &SystemService,
    ) -> StorageAuditResponse {
        let hls_base = cache_dir.join("hls");
        let previews_base = cache_dir.join("previews");

        let mut degraded_reasons = Vec::new();
        let mut media_roots_missing = Vec::new();

        // 1. Verify media roots exist
        for root in media_roots {
            if !root.is_dir() {
                media_roots_missing.push(root.to_string_lossy().to_string());
                degraded_reasons.push(format!(
                    "media enumeration is incomplete: configured root missing or unreadable: {}",
                    root.display()
                ));
            }
        }

        // 2. Discover active video files from database and filesystem
        let mut active_videos: Vec<PathBuf> = Vec::new();

        // From movies table
        if let Ok(rows) = sqlx::query_scalar::<_, String>("SELECT filename FROM movies")
            .fetch_all(pool)
            .await
        {
            for filename in rows {
                if let Ok(p) = PathResolver::resolve_media_path(&filename, media_roots) {
                    if p.is_file() && !active_videos.contains(&p) {
                        active_videos.push(p);
                    }
                }
            }
        }

        // Walk filesystem roots for video files
        for root in media_roots {
            if root.is_dir() {
                Self::walk_videos(root, &mut active_videos);
            }
        }

        // Also check active transcode jobs from PostgreSQL
        let mut active_job_filenames: HashSet<String> = HashSet::new();
        if let Ok(job_rows) = sqlx::query_scalar::<_, String>(
            "SELECT filename FROM transcode_jobs WHERE status IN ('queued', 'running')",
        )
        .fetch_all(pool)
        .await
        {
            for f in job_rows {
                active_job_filenames.insert(f);
            }
        }

        // If library is empty but caches exist, mark degraded
        if active_videos.is_empty() && degraded_reasons.is_empty() {
            for base in [&hls_base, &previews_base] {
                if base.is_dir() {
                    if let Ok(mut entries) = fs::read_dir(base) {
                        if entries.next().is_some() {
                            degraded_reasons.push(format!(
                                "media enumeration returned no videos while {} still holds cache directories",
                                base.display()
                            ));
                            break;
                        }
                    }
                }
            }
        }

        // 3. Map candidate keys to source files
        let mut active_hls_map: HashMap<String, PathBuf> = HashMap::new();
        let mut active_preview_map: HashMap<String, PathBuf> = HashMap::new();

        for p in &active_videos {
            let hls_candidates = HlsService::get_hls_candidates(p, media_roots);
            for cand in hls_candidates {
                active_hls_map.insert(cand, p.clone());
            }

            let preview_dir = PreviewService::get_preview_dir(p, cache_dir, media_roots);
            if let Some(name) = preview_dir.file_name() {
                active_preview_map.insert(name.to_string_lossy().to_string(), p.clone());
            }
            let preview_key = PreviewService::get_preview_key(p);
            active_preview_map.insert(preview_key, p.clone());
        }

        // Include active job keys
        let mut active_job_hls_keys: HashSet<String> = HashSet::new();
        for job_fn in &active_job_filenames {
            if let Ok(p) = PathResolver::resolve_media_path(job_fn, media_roots) {
                for cand in HlsService::get_hls_candidates(&p, media_roots) {
                    active_job_hls_keys.insert(cand);
                }
            }
        }

        // 4. Audit HLS cache directories
        let mut active_hls = Vec::new();
        let mut orphaned_hls = Vec::new();

        if hls_base.is_dir() {
            if let Ok(entries) = fs::read_dir(&hls_base) {
                for entry in entries.flatten() {
                    let d = entry.path();
                    if !d.is_dir() {
                        continue;
                    }
                    let dir_name = entry.file_name().to_string_lossy().to_string();
                    let (size_bytes, file_count, mtime) = Self::get_dir_size_and_mtime(&d);

                    let is_active = active_hls_map.contains_key(&dir_name)
                        || active_job_hls_keys.contains(&dir_name);
                    let source_file = active_hls_map
                        .get(&dir_name)
                        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()));

                    let item = CacheAuditItem {
                        name: dir_name,
                        path: d.to_string_lossy().to_string(),
                        size_bytes,
                        file_count,
                        mtime,
                        source_file,
                    };

                    if is_active {
                        active_hls.push(item);
                    } else {
                        orphaned_hls.push(item);
                    }
                }
            }
        }

        // 5. Audit Preview cache directories
        let mut active_previews = Vec::new();
        let mut orphaned_previews = Vec::new();

        if previews_base.is_dir() {
            if let Ok(entries) = fs::read_dir(&previews_base) {
                for entry in entries.flatten() {
                    let d = entry.path();
                    if !d.is_dir() {
                        continue;
                    }
                    let dir_name = entry.file_name().to_string_lossy().to_string();
                    let (size_bytes, file_count, mtime) = Self::get_dir_size_and_mtime(&d);

                    let is_active = active_preview_map.contains_key(&dir_name);
                    let source_file = active_preview_map
                        .get(&dir_name)
                        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()));

                    let item = CacheAuditItem {
                        name: dir_name,
                        path: d.to_string_lossy().to_string(),
                        size_bytes,
                        file_count,
                        mtime,
                        source_file,
                    };

                    if is_active {
                        active_previews.push(item);
                    } else {
                        orphaned_previews.push(item);
                    }
                }
            }
        }

        let degraded = !degraded_reasons.is_empty();
        if degraded {
            warn!(
                "Cache audit DEGRADED ({}) — refusing to classify any directory as orphaned",
                degraded_reasons.join("; ")
            );
            orphaned_hls.clear();
            orphaned_previews.clear();
        }

        let total_orphaned_bytes = orphaned_hls.iter().map(|i| i.size_bytes).sum::<u64>()
            + orphaned_previews.iter().map(|i| i.size_bytes).sum::<u64>();
        let total_active_bytes = active_hls.iter().map(|i| i.size_bytes).sum::<u64>()
            + active_previews.iter().map(|i| i.size_bytes).sum::<u64>();

        let telemetry = system_service.get_telemetry();

        StorageAuditResponse {
            storage: telemetry.storage,
            audit: CacheAuditData {
                total_orphaned_dirs: orphaned_hls.len() + orphaned_previews.len(),
                total_orphaned_bytes,
                total_active_dirs: active_hls.len() + active_previews.len(),
                total_active_bytes,
                orphaned_hls,
                orphaned_previews,
                active_hls,
                active_previews,
                degraded,
                degraded_reasons,
                media_roots_missing,
            },
        }
    }

    /// Purge orphaned cache directories with safety checks and Windows retry resilience.
    pub async fn purge_orphaned_caches(
        pool: &PgPool,
        media_roots: &[PathBuf],
        cache_dir: &Path,
        system_service: &SystemService,
        dry_run: bool,
    ) -> PurgeResult {
        // Refusal guard: Check if an active transcode or scan is in progress
        let active_jobs_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM transcode_jobs WHERE status IN ('queued', 'running')",
        )
        .fetch_one(pool)
        .await
        .unwrap_or(0);

        if active_jobs_count > 0 || ScanService::is_busy() {
            info!("Refusing cache purge: active transcode or library scan in progress");
            return PurgeResult {
                freed_bytes: 0,
                purged_count: 0,
                purged_dirs: Vec::new(),
                failed_count: 0,
                failed_dirs: Vec::new(),
                skipped_live_count: 0,
                skipped_live: Vec::new(),
                dry_run,
                refused: true,
                reason: Some("Transcode in progress".to_string()),
            };
        }

        // Audit current cache state
        let audit_res = Self::audit_caches(pool, media_roots, cache_dir, system_service).await;
        let audit = audit_res.audit;

        if audit.degraded {
            let reason = if audit.degraded_reasons.is_empty() {
                "cache audit degraded".to_string()
            } else {
                audit.degraded_reasons.join("; ")
            };
            warn!("Refusing cache purge: {}", reason);
            return PurgeResult {
                freed_bytes: 0,
                purged_count: 0,
                purged_dirs: Vec::new(),
                failed_count: 0,
                failed_dirs: Vec::new(),
                skipped_live_count: 0,
                skipped_live: Vec::new(),
                dry_run,
                refused: true,
                reason: Some(reason),
            };
        }

        let mut orphans = audit.orphaned_hls;
        orphans.extend(audit.orphaned_previews);

        let mut freed_bytes = 0u64;
        let mut purged_dirs = Vec::new();
        let mut failed_dirs = Vec::new();
        let mut skipped_live = Vec::new();

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        for item in orphans {
            let target = PathBuf::from(&item.path);

            // Fail-closed security: Ensure directory is strictly within approved cache root
            if !Self::is_within_cache_dir(&target, cache_dir) {
                warn!("Refusing to purge path outside cache root: {}", target.display());
                failed_dirs.push(serde_json::json!({
                    "path": item.path,
                    "remaining": "refused: outside approved cache root"
                }));
                continue;
            }

            // Live transcode grace window check
            if !dry_run && Self::looks_like_live_transcode(&target, now) {
                skipped_live.push(item.path.clone());
                warn!("Skipping cache directory in active use: {}", target.display());
                continue;
            }

            if dry_run {
                purged_dirs.push(item.path);
                freed_bytes += item.size_bytes;
                continue;
            }

            // Perform removal with retry resilience
            match Self::remove_path_with_retries(&target) {
                Ok(()) => {
                    purged_dirs.push(item.path);
                    freed_bytes += item.size_bytes;
                    info!("Purged orphaned cache directory: {}", target.display());
                }
                Err(err_msg) => {
                    failed_dirs.push(serde_json::json!({
                        "path": item.path,
                        "remaining": err_msg
                    }));
                    warn!("Failed to purge orphaned directory {}: {}", target.display(), err_msg);
                }
            }
        }

        PurgeResult {
            freed_bytes,
            purged_count: purged_dirs.len(),
            purged_dirs,
            failed_count: failed_dirs.len(),
            failed_dirs,
            skipped_live_count: skipped_live.len(),
            skipped_live,
            dry_run,
            refused: false,
            reason: None,
        }
    }

    /// Safely archive an original media source file whose HLS transcode is verified 100% complete.
    pub async fn archive_media(
        _pool: &PgPool,
        filename: &str,
        media_roots: &[PathBuf],
        cache_dir: &Path,
    ) -> Result<ArchiveResult, AppError> {
        let media_path = PathResolver::resolve_media_path(filename, media_roots)?;
        if !media_path.is_file() {
            return Err(AppError::NotFound("Media file not found.".to_string()));
        }

        // Verify HLS completion across root and tiered quality subdirectories
        let hls_dir = HlsService::find_hls_dir(&media_path, media_roots, cache_dir);
        let is_complete = HlsService::is_hls_complete(&hls_dir);

        if !is_complete {
            return Err(AppError::BadRequest(
                "Transcode is not yet 100% complete".to_string(),
            ));
        }

        // Determine destination archive directory
        let archive_base = std::env::var("MEDIA_SERVER_ARCHIVE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                media_roots
                    .first()
                    .map(|r| r.join(".archive"))
                    .unwrap_or_else(|| PathBuf::from("D:\\Flicks\\.archive"))
            });

        fs::create_dir_all(&archive_base)
            .map_err(|e| AppError::Internal(format!("Failed to create archive dir: {}", e)))?;

        let canon_source = media_path.canonicalize().unwrap_or_else(|_| media_path.clone());
        let canon_archive = archive_base.canonicalize().unwrap_or_else(|_| archive_base.clone());

        // Skip redundant move if source is already inside archive directory
        if canon_source.starts_with(&canon_archive) {
            info!("File is already in archive directory: {}", media_path.display());
            return Ok(ArchiveResult {
                status: "archived".to_string(),
                policy: "archive".to_string(),
                source: media_path.to_string_lossy().to_string(),
                archived_to: media_path.to_string_lossy().to_string(),
            });
        }

        // Determine clean relative path stripping `.archive`
        let file_name = media_path.file_name().unwrap_or_default();
        let mut rel_clean = PathBuf::from(file_name);

        for root in media_roots {
            if let Ok(rel) = media_path.strip_prefix(root) {
                let parts: Vec<_> = rel
                    .components()
                    .filter(|c| c.as_os_str() != ".archive")
                    .collect();
                if !parts.is_empty() {
                    let mut clean_p = PathBuf::new();
                    for part in parts {
                        clean_p.push(part);
                    }
                    rel_clean = clean_p;
                    break;
                }
            }
        }

        let target_path = archive_base.join(&rel_clean);
        if let Some(parent) = target_path.parent() {
            fs::create_dir_all(parent).map_err(|e| {
                AppError::Internal(format!("Failed to create archive subdir: {}", e))
            })?;
        }

        // Atomic move with copy fallback across Windows drives
        if canon_source != target_path.canonicalize().unwrap_or_else(|_| target_path.clone()) {
            let _ = fs::remove_file(&target_path);
            if let Err(rename_err) = fs::rename(&media_path, &target_path) {
                warn!(
                    "Rename failed ({}), falling back to cross-volume copy+delete: {} -> {}",
                    rename_err,
                    media_path.display(),
                    target_path.display()
                );
                fs::copy(&media_path, &target_path).map_err(|e| {
                    AppError::Internal(format!("Cross-volume copy failed: {}", e))
                })?;
                let _ = fs::remove_file(&media_path);
            }
            info!("Archived source media: {} -> {}", media_path.display(), target_path.display());
        }

        Ok(ArchiveResult {
            status: "archived".to_string(),
            policy: "archive".to_string(),
            source: media_path.to_string_lossy().to_string(),
            archived_to: target_path.to_string_lossy().to_string(),
        })
    }

    // --- Helper Functions ---

    fn is_within_cache_dir(child: &Path, parent: &Path) -> bool {
        let canon_parent = match parent.canonicalize() {
            Ok(p) => p,
            Err(_) => return false,
        };
        let canon_child = match child.canonicalize() {
            Ok(p) => p,
            Err(_) => return false,
        };
        canon_child.starts_with(&canon_parent) && canon_child != canon_parent
    }

    fn looks_like_live_transcode(dir: &Path, now: f64) -> bool {
        for pattern in ["hls.progress", "playlist.m3u8"] {
            let target = dir.join(pattern);
            if target.is_file() {
                if let Ok(meta) = target.metadata() {
                    if let Ok(m) = meta.modified() {
                        if let Ok(dur) = m.duration_since(UNIX_EPOCH) {
                            if (now - dur.as_secs_f64()) < RECENT_CACHE_GRACE_SECONDS {
                                return true;
                            }
                        }
                    }
                }
            }
        }
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with("chunk_") && name.contains(".m3u8") {
                    if let Ok(meta) = entry.metadata() {
                        if let Ok(m) = meta.modified() {
                            if let Ok(dur) = m.duration_since(UNIX_EPOCH) {
                                if (now - dur.as_secs_f64()) < RECENT_CACHE_GRACE_SECONDS {
                                    return true;
                                }
                            }
                        }
                    }
                }
            }
        }
        false
    }

    fn remove_path_with_retries(path: &Path) -> Result<(), String> {
        let mut last_err = String::new();
        for attempt in 1..=5 {
            match fs::remove_dir_all(path) {
                Ok(()) => return Ok(()),
                Err(e) => {
                    last_err = e.to_string();
                    std::thread::sleep(std::time::Duration::from_millis(50 * attempt));
                }
            }
        }
        Err(last_err)
    }

    fn get_dir_size_and_mtime(dir: &Path) -> (u64, usize, f64) {
        let mut total_size = 0u64;
        let mut file_count = 0usize;
        let mut latest_mtime = 0.0f64;

        Self::collect_dir_stats(dir, &mut total_size, &mut file_count, &mut latest_mtime);

        if latest_mtime == 0.0 {
            if let Ok(meta) = dir.metadata() {
                if let Ok(m) = meta.modified() {
                    if let Ok(dur) = m.duration_since(UNIX_EPOCH) {
                        latest_mtime = dur.as_secs_f64();
                    }
                }
            }
        }

        (total_size, file_count, latest_mtime)
    }

    fn collect_dir_stats(dir: &Path, total_size: &mut u64, file_count: &mut usize, latest_mtime: &mut f64) {
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_file() {
                    if let Ok(meta) = entry.metadata() {
                        *total_size += meta.len();
                        *file_count += 1;
                        if let Ok(m) = meta.modified() {
                            if let Ok(dur) = m.duration_since(UNIX_EPOCH) {
                                let sec = dur.as_secs_f64();
                                if sec > *latest_mtime {
                                    *latest_mtime = sec;
                                }
                            }
                        }
                    }
                } else if p.is_dir() {
                    Self::collect_dir_stats(&p, total_size, file_count, latest_mtime);
                }
            }
        }
    }

    fn walk_videos(dir: &Path, out: &mut Vec<PathBuf>) {
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_dir() {
                    Self::walk_videos(&p, out);
                } else if p.is_file() {
                    let ext = p
                        .extension()
                        .and_then(|e| e.to_str())
                        .map(|s| s.to_lowercase())
                        .unwrap_or_default();
                    if matches!(
                        ext.as_str(),
                        "mp4" | "m4v" | "mkv" | "webm" | "avi" | "mov"
                    ) {
                        if !out.contains(&p) {
                            out.push(p);
                        }
                    }
                }
            }
        }
    }

    /// Start periodic background cache maintenance daemon.
    ///
    /// Periodically executes `purge_orphaned_caches(&pool, &media_roots, &cache_dir, &system_service, false)`
    /// on the configured `interval`.
    pub fn start_daemon(
        pool: PgPool,
        media_roots: Arc<Vec<PathBuf>>,
        cache_dir: Arc<PathBuf>,
        interval: Duration,
        initial_delay: Duration,
        shutdown_flag: Arc<AtomicBool>,
    ) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            info!(
                "StorageService cache maintenance daemon started (interval: {:?}, initial delay: {:?})",
                interval, initial_delay
            );
            if !initial_delay.is_zero() {
                tokio::time::sleep(initial_delay).await;
            }

            let mut timer = tokio::time::interval(interval);
            timer.tick().await;

            let system_service = SystemService::new();

            while !shutdown_flag.load(Ordering::Relaxed) {
                timer.tick().await;
                if shutdown_flag.load(Ordering::Relaxed) {
                    break;
                }

                info!("Running periodic orphaned cache maintenance audit...");
                let result = Self::purge_orphaned_caches(
                    &pool,
                    &media_roots,
                    &cache_dir,
                    &system_service,
                    false,
                )
                .await;

                if result.refused {
                    warn!("Periodic cache maintenance refused: {:?}", result.reason);
                } else if result.purged_count > 0 {
                    info!(
                        "Periodic cache maintenance purged {} orphaned directories ({} bytes freed)",
                        result.purged_count, result.freed_bytes
                    );
                } else {
                    info!("Periodic cache maintenance complete: cache clean, 0 orphans found");
                }
            }
            info!("StorageService cache maintenance daemon stopped cleanly");
        })
    }
}
