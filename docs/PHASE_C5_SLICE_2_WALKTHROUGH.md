# Phase C5 Slice 2 — Device Management Parity (`GET /api/devices`, `/api/devices/rename`, `/api/devices/delete`) Verification Walkthrough

**Date:** 2026-10-16  
**Status:** COMPLETE & COMMITTED (`1a30efd`)  
**Branch:** `feat/rust-transcode-worker`  

---

## 1. Executive Summary & Deliverables

In Phase C5 Slice 2, we successfully ported the complete device management surface natively into the Rust Axum backend, eliminating the `/api/devices/*` reverse-proxy bridge group from `rust/src/lib.rs`. 

With this slice, **the proxied count on the Android client surface has fallen to ZERO (0)**. Every single endpoint requested by the client is now natively handled by Rust Axum on port `8001`.

### Key Changes Delivered:
1. **`rust/src/services/auth_service.rs`**:
   - Created reusable, fail-closed `AuthService::is_admin_authorized(&pool, &headers, body_pin)` helper.
   - Checks database `settings` (`admin_pin`). If unset or empty, auth fails closed immediately. PIN is accepted strictly from `X-Admin-Pin` header or request body (never from query strings).
2. **`rust/src/services/device_service.rs`**:
   - Implemented `DeviceService::get_all_devices`:
     - Queries `devices` and batch-queries `device_watch_history` joined with `movies` in a single query.
     - Formats clock time (`M:SS` / `H:MM:SS`), relative timestamps (`Just now`, `5m ago`), completion percentage, and device icons (`📱`, `📺`, `💻`, `🎮`).
     - Gated by admin status: non-admin callers receive only their own device with recomputed stats; admins receive the full fleet view.
   - Implemented `DeviceService::rename_device`: updates `custom_name` in `devices`.
   - Implemented `DeviceService::delete_device`: atomically purges watch history and device record within a database transaction.
3. **`rust/src/routes/devices.rs`**:
   - Implemented `list_devices_handler` (`GET /api/devices`), automatically touching caller heartbeat before returning device status.
   - Implemented `rename_device_handler` (`POST /api/devices/rename`), ensuring callers can only rename their own device unless authenticated as admin. Returns 400 for empty `device_id`.
   - Implemented `delete_device_handler` (`POST /api/devices/delete`), ensuring callers can only remove their own device unless authenticated as admin. Returns 400 for empty `device_id` and emits `Set-Cookie: ms_device_id=; Max-Age=0; Path=/` when deleting the active session device.
4. **`rust/src/lib.rs`**:
   - Mounted `list_devices_handler`, `rename_device_handler`, and `delete_device_handler` under `device_routes`.
   - **Removed `/api/devices` and `/api/devices/{*path}` from `proxy_routes`**, reducing reverse-proxy bridge groups from 5 down to 4 (`/auth/*`, `/api/auth/*`, `/api/admin/*`, `/api/storage/*`).
5. **Comprehensive Integration Tests**:
   - Extended [rust/tests/devices_test.rs](file:///e:/MediaServer/rust/tests/devices_test.rs) with 9 new tests (17 total in the suite) validating unauthenticated device filtering, admin fleet view, self-rename, 403 on renaming other devices, admin rename, self-delete with cookie expiration, 403 on deleting other devices, and admin delete.
   - Updated [rust/tests/proxy_bridge_test.rs](file:///e:/MediaServer/rust/tests/proxy_bridge_test.rs) to assert that `/api/devices` is answered natively and that unmigrated proxy tests target `/api/storage`.

---

## 2. Test Execution & Verification

### 2.1 Rust Automated Test Suite
All 237 test functions across all 18 test suites passed cleanly with zero failures:

```
running 103 tests in src/lib.rs ... ok. 103 passed; 0 failed
running 4 tests in tests/api_contracts_test.rs ... ok. 4 passed; 0 failed
running 12 tests in tests/cast_contract_test.rs ... ok. 12 passed; 0 failed
running 5 tests in tests/cors_scope_test.rs ... ok. 5 passed; 0 failed
running 17 tests in tests/devices_test.rs ... ok. 17 passed; 0 failed
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

Total: 237 passed; 0 failed; 0 ignored; 0 filtered out
```

### 2.2 Client Contract Probe
Executed [scripts/probe_android_api.py](file:///e:/MediaServer/scripts/probe_android_api.py) against both origins:

- **Flask `:8000`**: 22/22 passed per contract.
- **Rust `:8001`**: 22/22 passed per contract.
  - `GET 200 /api/devices`: verified native device list response matching expected contract.

---

## 3. Deployment Instruction for the User

To compile the release binary with Slice 2's native device management and restart the service, run:
```cmd
E:\MediaServer\scripts\restart_rust_service.bat
```
*(Accept the Windows UAC elevation prompt when displayed)*

Upon restart, verify the binary timestamp is newer than commit `1a30efd` (`2026-10-16 20:53:35`):
```powershell
Get-Item E:\MediaServer\rust\target\release\media-server-api.exe | Select LastWriteTime
```
