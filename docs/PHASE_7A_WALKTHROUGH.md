# Phase 7 — Slice 7A Walkthrough: Autonomous Background Daemon Parity in Rust

**Document Date:** 2026-10-17  
**Branch:** `feat/phase-7a-rust-background-daemons`  
**Commit:** `ec6b1d3`  
**Governing Documents:** `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md` §5 (Phase 7), `AGENTS.md` §0.1, §0.2, §5; `GEMINI.md` §0, §1, §3  

---

## 1. Executive Summary

Slice 7A delivers **100% background daemon parity** in the Rust Axum service with all automated background tasks previously maintained by Waitress/Flask. With this slice completed, Rust autonomously manages the full library lifecycle:
- Proactive multi-GPU transcode sweeping (`TranscodeSweeperService` — 5-minute interval).
- Concurrent chunk transcoding (`TranscodeWorker` — event-driven / queue-polled).
- Periodic media scanning and metadata indexing (`ScanService::start_daemon` — 1-hour interval, 30s initial delay).
- Periodic orphaned cache maintenance and safety auditing (`StorageService::start_daemon` — 2-hour interval, 120s initial delay).

All daemons are bound to a shared cooperative cancellation token (`shutdown_flag: Arc<AtomicBool>`), ensuring instant, clean termination on service shutdown without orphaned processes.

---

## 2. Key Deliverables & Changes

### 2.1 Autonomous Library Scanner Daemon ([`rust/src/services/scan_service.rs`](file:///e:/MediaServer/rust/src/services/scan_service.rs))
- Added `ScanService::start_daemon()`:
  - Spawns an asynchronous Tokio background loop.
  - Sleeps for an initial 30-second server warmup offset to avoid competing with boot-time operations.
  - Periodically checks configured media roots (`D:\Flicks`, `.archive`) every 3,600s (1 hour).
  - Skips ticks if a manual scan is already running via the `SCANNER_BUSY` atomic lock.
  - Returns a `tokio::task::JoinHandle<()>` enabling deterministic lifecycle testing.

### 2.2 Autonomous Cache Maintenance Daemon ([`rust/src/services/storage_service.rs`](file:///e:/MediaServer/rust/src/services/storage_service.rs))
- Added `StorageService::start_daemon()`:
  - Spawns an asynchronous Tokio background loop.
  - Sleeps for an initial 120-second warmup delay.
  - Periodically runs `StorageService::purge_orphaned_caches()` every 7,200s (2 hours).
  - Strictly enforces cache safety invariants: skips during active transcodes/scans, enforces the 600-second new cache grace period, and refuses if media roots are degraded or missing.
  - Logs freed disk bytes and orphaned directory cleanup statistics with structured tracing.

### 2.3 Main Application Entrypoint Wiring ([`rust/src/main.rs`](file:///e:/MediaServer/rust/src/main.rs))
- Created a shared cooperative cancellation flag: `let shutdown_flag = Arc::new(AtomicBool::new(false));`.
- Wired up all 4 background daemons concurrently:
  1. `TranscodeSweeperService::start_daemon(pool, roots, cache, 300s)`
  2. `TranscodeWorker::start_worker(pool, roots, cache, worker_id, shutdown_flag.clone())`
  3. `ScanService::start_daemon(base_dir, 3600s, 30s, shutdown_flag.clone())`
  4. `StorageService::start_daemon(pool, roots, cache, 7200s, 120s, shutdown_flag.clone())`
- Updated `shutdown_signal()` to set `shutdown_flag.store(true, Ordering::Relaxed)` upon `ctrl_c()`.

### 2.4 Dedicated Integration Test Suite ([`rust/tests/background_daemon_test.rs`](file:///e:/MediaServer/rust/tests/background_daemon_test.rs))
- Authored test cases verifying:
  - `test_scan_service_daemon_lifecycle_and_shutdown`: asserts daemon loops run, ticks trigger cleanly, and prompt shutdown is honored within milliseconds.
  - `test_storage_service_daemon_lifecycle_and_shutdown`: asserts storage cache maintenance daemon spins up and terminates cleanly upon shutdown signal.

---

## 3. Verification Evidence

### 3.1 Background Daemon Integration Tests (`background_daemon_test.rs`)
```text
running 2 tests
test test_scan_service_daemon_lifecycle_and_shutdown ... ok
test test_storage_service_daemon_lifecycle_and_shutdown ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; finished in 1.30s
```

### 3.2 Regression Suites (`storage_test.rs` & `scan_test.rs`)
```text
running 5 tests (scan_test)
test test_get_scan_returns_ok_status ... ok
test test_post_scan_rejects_query_string_pin ... ok
test test_post_scan_with_valid_body_pin_succeeds ... ok
test test_post_scan_without_admin_pin_returns_403 ... ok
test test_post_scan_with_valid_header_pin_succeeds ... ok
test result: ok. 5 passed; 0 failed; 0 ignored; finished in 2.08s

running 3 tests (storage_test)
test test_storage_settings_get_and_post ... ok
test test_storage_archive_endpoint ... ok
test test_storage_audit_and_purge ... ok
test result: ok. 3 passed; 0 failed; 0 ignored; finished in 1.45s
```

### 3.3 Core Library Suite (`cargo test --lib`)
```text
test result: ok. 103 passed; 0 failed; 0 ignored; finished in 2.06s
```

### 3.4 Android Client Contract Probe (`probe_android_api.py`)
```text
OK   GET  200  /api/movies                                                library list
OK   GET  200  /api/movie/2001%20A%20Space%20Odyssey%20%281968%29%20%5B   movie details
OK   GET  200  /api/system-status                                         telemetry
OK   GET  200  /api/devices                                               device list
OK   POST 200  /api/devices/heartbeat                                     heartbeat
OK   POST 200  /api/devices/client-hints                                  client hints
OK   GET  200  /api/transcode-status/2001%20A%20Space%20Odyssey%20%2819   transcode status
OK   GET  200  /api/progress?filename=2001%20A%20Space%20Odyssey%20%281   resume point
OK   GET  200  /api/media-info/2001%20A%20Space%20Odyssey%20%281968%29%   media info
OK   GET  200  /api/cast/devices                                          cast scan
OK   GET  400  /api/cast/status?device_id=probe-device-0001               cast status (400 = idle)
OK   POST 403  /api/scan                                                  manual scan trigger
OK   POST 404  /api/transcode/start/rust_probe_nonexistent_title.mkv      manual transcode start
OK   POST 400  /api/cast/play                                             cast play
OK   POST 400  /api/cast/control                                          cast control
OK   GET  404  /api/app/update?channel=production                         app update manifest
OK   GET  404  /api/app/download?channel=production                       apk download
OK   GET  200  /tmdb-poster/62                                            tmdb poster
OK   GET  200  /media/2001%20A%20Space%20Odyssey%20%281968%29%20%5BBluR   media delivery
OK   GET  200  /hls/2001%20A%20Space%20Odyssey%20%281968%29%20%5BBluRay   hls playlist
OK   GET  404  /subtitles/2001%20A%20Space%20Odyssey%20%281968%29%20%5B   subtitles
OK   GET  404  /poster/does-not-exist.jpg                                 poster route

RESULT: all 22 Android client endpoints respond per contract
```

### 3.5 Release Compilation Check (`cargo check --release`)
```text
Finished `release` profile [optimized] target(s) in 17.68s (0 errors, 0 warnings)
```

---

## 4. Next Step: Slice 7B (Production Port 8000 Cutover)

With autonomous background daemon parity fully satisfied and verified:
1. Reconfigure Rust configuration default port to `:8000` in [`rust/src/config.rs`](file:///e:/MediaServer/rust/src/config.rs) and update NSSM environment registry (`RUST_PORT=8000`).
2. Stop the legacy `MediaServer` (Waitress WSGI) service to release port `:8000`.
3. Start `MediaServerRust` on port `:8000`.
4. Verify Cloudflare tunnel (`media.anisparvez.in` $\rightarrow$ `127.0.0.1:8000`) connects directly to Rust Axum.
