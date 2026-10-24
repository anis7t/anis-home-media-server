# Walkthrough — Sub-Slice 7E.3: Legacy Python Backend (`app/`) & Launchers Decommissioning

## 1. Overview & Objective
Sub-Slice 7E.3 represents the core milestone of **Phase 7 Backlog: Slice 7E (Legacy Flask Retirement)**.
The objective of this sub-slice was to permanently retire the entire legacy Python Flask backend package (`app/`) and all obsolete root WSGI launcher scripts (`app.py`, `run_production.py`, `gunicorn.conf.py`, `server.sh`, `posters.py`), while decoupling `scanner.py` into a 100% self-contained tool with zero project imports.

All backend routing, media streaming, HLS transcoding, background workers, and device management are now executed natively by `MediaServerRust` (`rust/`) on port 8000.

---

## 2. Completed Actions

### A. Decoupled `scanner.py` into a Standalone Tool
- Eliminated all imports from `app.*` (`from app.db import ...`, `from app import config`, `from app.services.media_resolver import ...`, `from app.utils.filesystem import ...`).
- Embedded the poster and backdrop downloader directly inside `scanner.py`, eliminating `posters.py`.
- Implemented direct PostgreSQL connectivity via `psycopg.connect(DATABASE_URL)` (with SQLite fallback if unset) and automatic SQL parameter translation (`?` -> `%s`).
- Implemented module-local media root resolution (`MEDIA_SERVER_MEDIA_ROOT` / `D:/Flicks`).
- Verified standalone execution with both global Python and project virtualenv.

### B. Decommissioned Legacy Python Application Package (`app/`)
- Completely deleted the `app/` directory tree (35 files):
  - `app/__init__.py` (Flask application factory)
  - `app/config.py` (legacy Python configuration)
  - `app/db.py` (legacy SQLite & psycopg adapter)
  - `app/routes/` (`admin.py`, `api.py`, `auth.py`, `cast.py`, `media.py`, `pages.py`, `subtitles.py`, `upload.py`)
  - `app/services/` (`auth_service.py`, `backup_service.py`, `cast_service.py`, `chunk_transcode_service.py`, `device_service.py`, `google_auth.py`, `gpu_service.py`, `media_resolver.py`, `media_service.py`, `oauth_store.py`, `preview_service.py`, `scanner_service.py`, `subtitles_service.py`, `system_service.py`, `tmdb_service.py`, `token_service.py`, `transcode_service.py`, `worker_service.py`)
  - `app/utils/` (`filesystem.py`, `formatting.py`, `subtitles.py`)

### C. Decommissioned Obsolete Root Launchers
- Deleted `app.py` (legacy WSGI factory export)
- Deleted `run_production.py` (Waitress production runner)
- Deleted `gunicorn.conf.py` (Gunicorn production runner)
- Deleted `posters.py` (absorbed into `scanner.py`)
- Deleted `server.sh` (legacy shell launcher)

---

## 3. Verification & Test Outcomes

### A. Standalone Scanner Verification
```powershell
python scanner.py
venv\Scripts\python.exe scanner.py
```
**Outcome**: Both executed with exit code 0 and zero import errors with `app/` completely absent.

### B. Rust Library Scan Integration Tests
```powershell
cargo test --test scan_test # (in rust/)
```
**Outcome**:
- `test_get_scan_returns_ok_status` — **PASSED**
- `test_post_scan_with_valid_body_pin_succeeds` — **PASSED**
- `test_post_scan_with_valid_header_pin_succeeds` — **PASSED**
- `test_post_scan_without_admin_pin_returns_403` — **PASSED**
- `test_post_scan_rejects_query_string_pin` — **PASSED**
All **5/5** tests passed.

### C. Client API Contract Probes
```powershell
python scripts/probe_android_api.py
python scripts/probe_phase_8_contracts.py
```
**Outcome**:
- **22/22** Android API contracts responded per contract.
- All Phase 8 adaptive streaming, quality ladder, and client direct play assertions passed.

---

## 4. Next Step
Sub-Slice 7E.3 is complete. Ready for **Sub-Slice 7E.4: Test Suite Modernization & Python Dependency Pruning (`requirements.txt`)**.
