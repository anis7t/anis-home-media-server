# Phase C5 Slice 1 — Native `/api/scan` & `/api/transcode/start` Verification Walkthrough

**Date:** 2026-10-16  
**Status:** COMPLETE & COMMITTED (`68538e1`)  
**Branch:** `feat/rust-transcode-worker`  

---

## 1. Executive Summary & Deliverables

In Phase C5 Slice 1, we successfully ported the `/api/scan` endpoint natively into the Rust Axum backend, added the `/api/transcode/start/{*path}` compatibility route delegating to `JobService::enqueue`, and removed `/api/scan` from the Flask proxy bridge in `rust/src/lib.rs`.

### Changes Summary:
1. **`rust/src/config.rs`**:
   - Added `pub base_dir: PathBuf` to `AppConfig`, dynamically resolved from `MEDIA_SERVER_BASE_DIR` or defaulting to current execution directory.
2. **`rust/src/services/scan_service.rs`**:
   - Created native `ScanService` with an atomic busy lock (`SCANNER_BUSY: AtomicBool`).
   - Implemented `is_admin_authorized()` querying `SELECT value FROM settings WHERE key = 'admin_pin'`. Fail-closed semantics strictly enforced: if unset, no PIN is valid. PIN accepted strictly via `X-Admin-Pin` header or JSON body `admin_pin` (never from query string).
   - Asynchronously triggers scanner process `python scanner.py` under `base_dir`.
3. **`rust/src/routes/scan.rs`**:
   - Implemented `GET /api/scan` and `POST /api/scan` returning identical contract shape:
     `{"status": "ok", "busy": bool, "transcodes_queued": 0, "transcodes_running": 0}`.
4. **`rust/src/routes/transcode.rs`**:
   - Implemented `POST /api/transcode/start/{*path}` handler.
   - Decodes URL-encoded filenames, resolves across configured media roots via `PathResolver::resolve_media_path`, rejects non-video extensions and missing files with 404, checks if directly playable or cached HLS, and enqueues transcode jobs into `JobService`.
   - Stripped Windows extended-length UNC prefixes (`\\?\`) to ensure deterministic key matching in the database queue.
5. **`rust/src/lib.rs`**:
   - Mounted `scan_routes` and `transcode_routes`.
   - Removed `/api/scan` from `proxy_routes` (reducing reverse-proxy bridge groups from 6 down to 5).
6. **`scripts/probe_android_api.py`**:
   - Tightened assertion: `/api/scan` now validates against `(200, 401, 403)`, and `/api/transcode/start` with a synthetic filename asserts `(404,)` rather than accepting false positives.
7. **Comprehensive Unit & Integration Test Battery**:
   - Added `rust/tests/scan_test.rs` (5 tests covering GET 200, unauthorized POST 403, query parameter rejection 403, valid header PIN 200, and valid body PIN 200).
   - Added `rust/tests/transcode_start_test.rs` (3 tests covering 404 on nonexistent files, 200 ready on direct-playable files, and 200 queued on MKV files).

---

## 2. Test Execution & Verification

### 2.1 Rust Automated Test Suite
All 228 test functions across the entire repository passed with zero failures:

```
running 103 tests in src/lib.rs ... ok. 103 passed; 0 failed
running 4 tests in tests/api_contracts_test.rs ... ok. 4 passed; 0 failed
running 12 tests in tests/cast_contract_test.rs ... ok. 12 passed; 0 failed
running 5 tests in tests/cors_scope_test.rs ... ok. 5 passed; 0 failed
running 8 tests in tests/devices_test.rs ... ok. 8 passed; 0 failed
running 10 tests in tests/hls_transcode_test.rs ... ok. 10 passed; 0 failed
running 12 tests in tests/job_queue_test.rs ... ok. 12 passed; 0 failed
running 7 tests in tests/media_info_test.rs ... ok. 7 passed; 0 failed
running 8 tests in tests/poster_asset_test.rs ... ok. 8 passed; 0 failed
running 9 tests in tests/preview_test.rs ... ok. 9 passed; 0 failed
running 1 test in tests/progress_contracts_test.rs ... ok. 1 passed; 0 failed
running 7 tests in tests/proxy_bridge_test.rs ... ok. 7 passed; 0 failed
running 5 tests in tests/scan_test.rs ... ok. 5 passed; 0 failed
running 5 tests in tests/spa_serving_test.rs ... ok. 5 passed; 0 failed
running 11 tests in tests/streaming_range_test.rs ... ok. 11 passed; 0 failed
running 16 tests in tests/subtitles_test.rs ... ok. 16 passed; 0 failed
running 10 tests in tests/tmdb_artwork_test.rs ... ok. 10 passed; 0 failed
running 3 tests in tests/transcode_start_test.rs ... ok. 3 passed; 0 failed

Total: 228 passed; 0 failed; 0 ignored; 0 filtered out
```

### 2.2 Client Contract Probe
Executed `scripts/probe_android_api.py` against both origins (`:8000` Flask and `:8001` Rust):

- **Flask `:8000`**: 22/22 passed per contract.
- **Rust `:8001`**: 22/22 passed per contract.
  - `POST 403 /api/scan`: manual scan trigger verified fail-closed without admin credentials.
  - `POST 404 /api/transcode/start/rust_probe_nonexistent_title.mkv`: verified safe synthetic 404 handling without side effects.

---

## 3. Deployment Instruction for the User

Because the `MediaServerRust` production Windows Service holds a file lock on `rust\target\release\media-server-api.exe`, recompilation and service restart require an elevated administrator action.

Please execute the restart script to deploy the release binary:
1. Double-click or run:
   ```cmd
   E:\MediaServer\scripts\restart_rust_service.bat
   ```
   *(Accept the Windows UAC elevation prompt when displayed)*
2. Or via an elevated PowerShell terminal:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File E:\MediaServer\scripts\restart_rust_service.ps1
   ```

Upon completion, verify the binary timestamp is newer than the git commit timestamp (`2026-10-16 20:28:00`):
```powershell
Get-Item E:\MediaServer\rust\target\release\media-server-api.exe | Select LastWriteTime
```
