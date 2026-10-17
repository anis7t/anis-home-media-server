# Phase 7 — Slice 7D Walkthrough: Operational Tooling & Script Harmonization

**Document Date:** 2026-10-18  
**Branch:** `feat/phase-7d-operational-tooling`  
**Governing Documents:** `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`, `AGENTS.md` §0.1, §0.2, §5; `GEMINI.md` §0, §1, §18  

---

## 1. Executive Summary

With Rust Axum and the React SPA successfully unified on port `8000` (**Slice 7B**) and all system contracts verified (**Slice 7C**), **Slice 7D** harmonizes the repository's operational script inventory in `scripts/`.

### Key Deliverables:
1. **Single Canonical Service Restarter (`scripts/restart_service.bat`)**:
   - Upgraded `restart_service.bat` to be the primary, authoritative restarter.
   - Automatically requests UAC elevation and invokes `restart_rust_service.ps1`, restarting `MediaServerRust` and executing the full health diagnostic.
   - `scripts/restart_rust_service.bat` aliased directly to `restart_service.bat` for backward compatibility.
2. **Authoritative Health Diagnostic (`scripts/service_status.ps1`)**:
   - Modernized `service_status.ps1` into a comprehensive multi-service health monitor:
     * Windows Services: `MediaServerRust` (Active), `MediaServerPG` (Active), `Cloudflared` (Active), and `MediaServer` (Decommissioned/Stopped).
     * Port Listeners: Port `8000` (`media-server-api`) and Port `5432` (`postgres`).
     * Port `8001`: Asserts that retired port 8001 is closed and released.
     * HTTP Probes: Local SPA (`http://127.0.0.1:8000/`), Local API (`http://127.0.0.1:8000/api/movies`), and Cloudflare Ingress (`https://media.anisparvez.in/health`).
     * Active Transcode Telemetry: Reports active chunked transcoding jobs and worker PIDs.
     * Log Tails: Displays latest log entries from `logs/rust_api.log` and `logs/rust_api_error.log`.
   - `scripts/rust_service_status.ps1` aliased to `service_status.ps1`.
3. **Decoupled 5-Minute Watchdog (`scripts/service_watchdog.ps1`)**:
   - Decoupled legacy `MediaServer` from the scheduled maintenance loop (`$services = @("MediaServerRust")`).
   - Ensures the background scheduled task maintains PostgreSQL and Rust without ever resurrecting or restarting Flask.
   - Verified via `-DryRun`.
4. **Port 8000 Alignment Across Tooling**:
   - Updated installer defaults in `scripts/install_rust_service.ps1` to port `8000`.
   - Updated default connection targets from `8001` to `8000` across benchmarking and verification scripts:
     * `scripts/benchmark_real_movie_transcode.py`
     * `scripts/benchmark_streaming.py`
     * `scripts/verify_cast_live.py`
     * `scripts/verify_phase_8_live_fmp4.py`
     * `scripts/verify_rust_transcode_live.py`
     * `scripts/verify_phase_2r_d_e2e.py`
     * `scripts/verify_rust_spa_live.py`
     * `scripts/probe_android_api.py`
5. **Automated PostgreSQL Backup Tooling (`scripts/backup_postgres.bat` & `.ps1`)**:
   - Created native backup utility locating `pg_dump.exe` across standard installation roots.
   - Generates compressed, custom-format dumps (`.dump`) in `E:\MediaServer\backups\postgres\`.
   - Implements automated timestamped naming (`media_server_YYYYMMDD_HHMMSS.dump`) and retention pruning (preserves newest 7 backups).
   - Tested and verified: backed up 12 tables (0.09 MB) cleanly.

---

## 2. Verification Battery & Outcomes

| Test / Probe | Target | Result | Details |
| :--- | :--- | :---: | :--- |
| `service_watchdog.ps1 -DryRun` | Local SCM | **PASS** | Evaluated `MediaServerRust` and `MediaServerPG`; ignored decommissioned `MediaServer`. |
| `backup_postgres.ps1` | `127.0.0.1:5432` | **PASS** | Generated `media_server_20261017_235548.dump` with 12 tables and verified retention. |
| `probe_phase_8_contracts.py` | `http://127.0.0.1:8000` | **PASS** | Web MKV transcode evaluation, Android zero-copy direct play, 720p status & start verified. |
| `service_status.ps1` | Multi-tier | **PASS** | All services green, ports verified, HTTP 200 on SPA and API. |
| Active Transcode Telemetry | AMD Dual GPU | **ACTIVE** | Job #794 (*Ghost in the Cell* 1440p) running on RX 560X + Vega 8. |

---

## 3. Documentation & Setup Harmonization

- [`docs/WINDOWS_SETUP.md`](WINDOWS_SETUP.md): Fully updated to document `MediaServerRust` as the primary production service on port `8000`, record `MediaServer` as decommissioned/manual, document the harmonized restarter and diagnostic scripts, and record the new PostgreSQL backup utility.
- [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md): Updated modernization roadmap table to record completed Phase 6, Phase 8, and Phase 7 Slices 7A-7D.
- [`docs/MIGRATION_STATUS.md`](MIGRATION_STATUS.md): Current session handoff updated to reflect Slice 7A-7D deliverables and active transcode status.

---

## 4. Next Step: Phase 7 Slice 7E

With operational tooling completely harmonized, the final slice is **Slice 7E (Legacy Flask Retirement & Final Sign-off)**:
1. Decommission and remove legacy `app/` Python routes and services.
2. Remove deprecated Flask WSGI service wrappers.
3. Mark Phase 7 and the full migration complete.
