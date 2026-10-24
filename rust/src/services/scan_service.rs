use crate::scanner::{ScannerEngine, ScannerReport};
use axum::http::HeaderMap;
use sqlx::PgPool;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tracing::{error, info};

static SCANNER_BUSY: AtomicBool = AtomicBool::new(false);

fn last_report() -> &'static Mutex<Option<ScannerReport>> {
    static REPORT: OnceLock<Mutex<Option<ScannerReport>>> = OnceLock::new();
    REPORT.get_or_init(|| Mutex::new(None))
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ScanResponse {
    pub status: String,
    pub busy: bool,
    pub files_discovered: usize,
    pub unindexed_discovered: usize,
    pub movies_indexed: usize,
    pub orphans_pruned: usize,
    pub subtitles_acquired: usize,
    pub errors: usize,
    pub transcodes_queued: u64,
    pub transcodes_started: u64,
    pub transcodes_skipped: u64,
    pub transcodes_errors: u64,
}

pub struct ScanService;

impl ScanService {
    /// Check whether a library scan is currently running.
    pub fn is_busy() -> bool {
        SCANNER_BUSY.load(Ordering::SeqCst)
    }

    /// Set busy flag directly (for testing / mocking purposes).
    #[cfg(test)]
    pub fn set_busy_for_test(busy: bool) {
        SCANNER_BUSY.store(busy, Ordering::SeqCst);
    }

    /// Get telemetry snapshot of the last completed scan.
    pub fn get_last_report() -> Option<ScannerReport> {
        last_report().lock().ok().and_then(|guard| guard.clone())
    }

    /// Trigger an in-process native library scan if not already running.
    ///
    /// Spawns an asynchronous task executing `ScannerEngine::scan`.
    /// Returns `true` if a new scan process was started, or `false` if one was already running.
    pub fn trigger_scan(
        pool: Arc<PgPool>,
        media_roots: Arc<Vec<PathBuf>>,
        cache_dir: Arc<PathBuf>,
        tmdb_token: Option<String>,
    ) -> bool {
        if SCANNER_BUSY
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return false;
        }

        tokio::spawn(async move {
            let _guard = ScannerLockGuard;
            info!("Triggering native in-process library scan across {} media root(s)...", media_roots.len());

            match ScannerEngine::scan(
                &pool,
                &media_roots,
                &cache_dir,
                tmdb_token.as_deref(),
            )
            .await
            {
                Ok(report) => {
                    info!("Native library scan completed successfully: {:?}", report);
                    if let Ok(mut lock) = last_report().lock() {
                        *lock = Some(report);
                    }
                }
                Err(err) => {
                    error!("Native library scan failed: {}", err);
                }
            }
        });

        true
    }

    /// Start periodic background library scanner daemon.
    ///
    /// Periodically executes `trigger_scan` on the configured `interval`.
    /// Skips tick if a scan is already active or if `shutdown_flag` is set.
    pub fn start_daemon(
        pool: PgPool,
        media_roots: Arc<Vec<PathBuf>>,
        cache_dir: Arc<PathBuf>,
        tmdb_token: Option<String>,
        interval: Duration,
        initial_delay: Duration,
        shutdown_flag: Arc<AtomicBool>,
    ) -> tokio::task::JoinHandle<()> {
        let pool_arc = Arc::new(pool);
        tokio::spawn(async move {
            info!(
                "ScanService native background daemon started (interval: {:?}, initial delay: {:?})",
                interval, initial_delay
            );
            if !initial_delay.is_zero() {
                tokio::time::sleep(initial_delay).await;
            }

            let mut timer = tokio::time::interval(interval);
            timer.tick().await;

            while !shutdown_flag.load(Ordering::Relaxed) {
                timer.tick().await;
                if shutdown_flag.load(Ordering::Relaxed) {
                    break;
                }

                if !Self::is_busy() {
                    info!("Periodic native background library scan triggered");
                    Self::trigger_scan(
                        pool_arc.clone(),
                        media_roots.clone(),
                        cache_dir.clone(),
                        tmdb_token.clone(),
                    );
                } else {
                    info!("Periodic background library scan skipped: scanner already active");
                }
            }
            info!("ScanService background daemon stopped cleanly");
        })
    }

    /// Verify whether a request is administrator-authorized (via valid configured Admin PIN).
    ///
    /// Per AGENTS.md §4:
    /// - The Admin PIN fails closed, and has no default.
    /// - Unset/empty in database means the PIN channel is CLOSED (returns false).
    /// - Accepts PIN only from `X-Admin-Pin` header or request body. NEVER from query string.
    pub async fn is_admin_authorized(
        pool: &PgPool,
        headers: &HeaderMap,
        body_pin: Option<&str>,
    ) -> bool {
        crate::services::auth_service::AuthService::is_admin_authorized(pool, headers, body_pin).await
    }
}

/// RAII Guard ensuring SCANNER_BUSY is cleared even if the tokio task panics.
struct ScannerLockGuard;

impl Drop for ScannerLockGuard {
    fn drop(&mut self) {
        SCANNER_BUSY.store(false, Ordering::SeqCst);
    }
}
