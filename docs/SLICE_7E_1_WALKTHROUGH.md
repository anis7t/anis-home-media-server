# Walkthrough — Sub-Slice 7E.1: Operational Scripts Audit & Tooling Modernization

## 1. Overview & Objective
Sub-Slice 7E.1 represents the first milestone of **Phase 7 Backlog: Slice 7E (Legacy Flask Retirement)**.
The objective of this sub-slice was to audit the 54 scripts in `scripts/`, safeguard and isolate all active operational tools, and decommission 30 obsolete Flask-era scripts, historical one-off migration tools, and defunct SQLite utilities.

---

## 2. Completed Actions

### A. Operational Tooling Preserved & Verified (17 Active Core Tools)
- **API & Adaptive Stream Contract Probes**:
  - [`scripts/probe_android_api.py`](file:///e:/MediaServer/scripts/probe_android_api.py): 22/22 contract endpoints verified against live service.
  - [`scripts/probe_phase_8_contracts.py`](file:///e:/MediaServer/scripts/probe_phase_8_contracts.py): Verified fMP4 adaptive streaming, dynamic quality ladder, and client-aware MKV direct play.
  - [`scripts/verify_phase_8_live_fmp4.py`](file:///e:/MediaServer/scripts/verify_phase_8_live_fmp4.py): Real hardware fMP4 transcode verification tool.
  - [`scripts/verify_cast_live.py`](file:///e:/MediaServer/scripts/verify_cast_live.py): Google Cast / DLNA receiver live control tool.
  - [`scripts/verify_rust_spa_live.py`](file:///e:/MediaServer/scripts/verify_rust_spa_live.py): Selenium E2E SPA test.
  - [`scripts/live_player_seek_check.py`](file:///e:/MediaServer/scripts/live_player_seek_check.py): Live player boundary seek checker.
- **PostgreSQL 18.4 Database Management**:
  - [`scripts/backup_postgres.bat`](file:///e:/MediaServer/scripts/backup_postgres.bat) & [`scripts/backup_postgres.ps1`](file:///e:/MediaServer/scripts/backup_postgres.ps1): Live database backup via `pg_dump`.
  - [`scripts/start_postgres.bat`](file:///e:/MediaServer/scripts/start_postgres.bat) & [`scripts/stop_postgres.bat`](file:///e:/MediaServer/scripts/stop_postgres.bat): Database service controllers.
- **Windows Service Lifecycle (`MediaServerRust`)**:
  - [`scripts/restart_rust_service.bat`](file:///e:/MediaServer/scripts/restart_rust_service.bat) & [`scripts/restart_rust_service.ps1`](file:///e:/MediaServer/scripts/restart_rust_service.ps1).
  - [`scripts/restart_service.bat`](file:///e:/MediaServer/scripts/restart_service.bat): Production wrapper delegating to `restart_rust_service.ps1`.
  - [`scripts/install_rust_service.bat`](file:///e:/MediaServer/scripts/install_rust_service.bat) & [`scripts/install_rust_service.ps1`](file:///e:/MediaServer/scripts/install_rust_service.ps1).
  - [`scripts/uninstall_rust_service.bat`](file:///e:/MediaServer/scripts/uninstall_rust_service.bat) & [`scripts/uninstall_rust_service.ps1`](file:///e:/MediaServer/scripts/uninstall_rust_service.ps1).
  - [`scripts/rust_service_status.ps1`](file:///e:/MediaServer/scripts/rust_service_status.ps1) & [`scripts/service_status.ps1`](file:///e:/MediaServer/scripts/service_status.ps1).
- **Client & Build Automation**:
  - [`scripts/publish_update.py`](file:///e:/MediaServer/scripts/publish_update.py) & [`scripts/release_android.py`](file:///e:/MediaServer/scripts/release_android.py).
  - [`scripts/run_flutter_tests.ps1`](file:///e:/MediaServer/scripts/run_flutter_tests.ps1).
  - [`scripts/cargo.bat`](file:///e:/MediaServer/scripts/cargo.bat).
  - [`scripts/update_intro_doc.py`](file:///e:/MediaServer/scripts/update_intro_doc.py).

### B. Service Status Modernization
- Updated [`scripts/service_status.ps1`](file:///e:/MediaServer/scripts/service_status.ps1) to remove deprecated `"MediaServer"` from the active Windows Service query, auditing strictly:
  - `MediaServerRust` (Automatic, Running)
  - `MediaServerPG` (Automatic, Running)
  - `Cloudflared` (Automatic, Running)

### C. 30 Obsolete Flask-Era Scripts Decommissioned
- **Legacy Flask Service Installers & Watchdogs**:
  - `scripts/install_service.bat`, `install_service.ps1`, `uninstall_service.bat`, `uninstall_service.ps1`
  - `scripts/install_watchdog.bat`, `install_watchdog.ps1`, `service_watchdog.ps1`, `uninstall_watchdog.ps1`
- **Completed One-Off Migration & Repointing Tools**:
  - `scripts/cutover_port_8000.bat`, `cutover_port_8000.ps1`
  - `scripts/migrate_sqlite_to_postgres.py`, `snapshot_live_data.py`
  - `scripts/move_nssm_to_c.ps1`, `move_pg_to_c.ps1`
- **Obsolete SQLite Database Tools**:
  - `scripts/backup_database.bat`, `backup_database.py`, `restore_database.py`
- **Historical Flask HLS & Transcode Debugging Scripts**:
  - `scripts/hls_completeness_report.py`, `hls_content_gap_inventory.py`, `hls_frame_audit.py`, `hls_gop_matrix.py`
  - `scripts/hls_layout_migration_check.py`, `hls_per_gpu_segments.py`, `hls_pipeline_regression.py`, `hls_restore_endlist.py`
  - `scripts/final_verification_battery.py`, `benchmark_streaming.py`, `benchmark_real_movie_transcode.py`
  - `scripts/verify_rust_transcode_live.py`, `verify_phase_2r_d_e2e.py`

---

## 3. Verification & Test Outcomes

### A. Android Client API Contract Verification
```powershell
python scripts/probe_android_api.py
```
**Outcome**: All **22/22** endpoints responded per contract (HTTP 200/400/404 expected status codes).

### B. Phase 8 Adaptive Streaming & Client Direct Play Verification
```powershell
python scripts/probe_phase_8_contracts.py
```
**Outcome**:
- Web client MKV correctly requires transcode and exposes multi-bitrate ladder (720p, 480p, 360p) with zero upscaling.
- Android client MKV correctly evaluated for zero-copy RFC 7233 direct play.
- Quality-specific start and status endpoints verified.

### C. Full Service Health & Listener Check
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/service_status.ps1
```
**Outcome**:
- `MediaServerRust`, `MediaServerPG`, and `Cloudflared` report `Running (Automatic)`.
- Rust/Axum listening on port 8000.
- PostgreSQL listening on port 5432.
- Local Health (`/health`), Local SPA (`/`), and Public Tunnel (`media.anisparvez.in`) all report 200 OK.

### D. Full Rust & React Test Batteries
- **Rust Backend**: 103 unit tests + 15 integration test suites pass.
- **Web Frontend**: **212/212** Vitest tests pass across 30 test files.
- **Web Production Bundle**: Clean build in **811ms** (`tsc -b && vite build`).

---

## 4. Next Step
Sub-Slice 7E.1 is complete. Ready for **Sub-Slice 7E.2: Legacy UI Templates & Static Asset Retirement** (`templates/`, `static/`).
