use axum::http::HeaderMap;
use sqlx::PgPool;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use tracing::{error, info};

static SCANNER_BUSY: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ScanResponse {
    pub status: String,
    pub busy: bool,
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

    /// Trigger an asynchronous library scan if not already running.
    ///
    /// Spawns `scanner.py` using the project's virtualenv Python under the given base directory.
    /// Returns `true` if a new scan process was started, or `false` if one was already running.
    pub fn trigger_scan(base_dir: &Path) -> bool {
        if SCANNER_BUSY
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return false;
        }

        let base_dir_buf = base_dir.to_path_buf();
        tokio::spawn(async move {
            let _guard = ScannerLockGuard;

            // Determine virtualenv Python binary
            let py_exe = Self::resolve_python_executable(&base_dir_buf);
            let scanner_script = base_dir_buf.join("scanner.py");

            if !scanner_script.exists() {
                error!(
                    "Cannot trigger library scan: scanner.py not found at {}",
                    scanner_script.display()
                );
                return;
            }

            info!(
                "Triggering background library scan with {} on {}",
                py_exe.display(),
                scanner_script.display()
            );

            let mut cmd = tokio::process::Command::new(&py_exe);
            cmd.arg("scanner.py")
                .current_dir(&base_dir_buf)
                .env("MEDIA_SERVER_BASE_DIR", &base_dir_buf);

            match cmd.status().await {
                Ok(status) => {
                    info!("Background library scan completed with status: {}", status);
                }
                Err(err) => {
                    error!("Background library scan failed to spawn or execute: {}", err);
                }
            }
        });

        true
    }

    /// Resolve the path to Python inside virtual environment, with system fallbacks.
    fn resolve_python_executable(base_dir: &Path) -> PathBuf {
        let win_venv = base_dir.join("venv").join("Scripts").join("python.exe");
        if win_venv.exists() {
            return win_venv;
        }
        let nix_venv = base_dir.join("venv").join("bin").join("python");
        if nix_venv.exists() {
            return nix_venv;
        }
        PathBuf::from("python")
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
