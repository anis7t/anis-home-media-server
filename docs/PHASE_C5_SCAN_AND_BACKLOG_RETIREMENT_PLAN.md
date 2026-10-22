# Phase C5: Native Scan API & Bridge Backlog Retirement Plan

**Date:** 2026-10-16  
**Branch:** `feat/rust-transcode-worker`  
**Status:** PROPOSED — Pending User Approval  
**Governing Documents:** `AGENTS.md` §0 & §4, `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`, `docs/PHASE_7_FLASK_RETIREMENT.md`

---

## 1. Context and Strategic Objective

The repository is currently migrating from Flask (`:8000`) to native Rust/Axum (`:8001`). Cast and DLNA streaming are now 100% native (Phase C4a/C4b). The temporary hybrid proxy bridge in `rust/src/lib.rs:330-347` forwards 6 route groups back to Flask. Per `AGENTS.md` §0.2, this bridge contradicts the Native Independence Invariant and represents the active debt backlog.

In addition, two verified compatibility gaps were identified in the latest session handoff:
1. `POST /api/transcode/start/{*filename}` exists in Flask (`app/routes/api.py:357`) and is called by the Flutter client (`library_repository.dart:100`), but is absent in Rust (404 into SPA fallback).
2. `scripts/probe_android_api.py` accepts lax 404s for both `/api/scan` and `/api/transcode/start`.

This plan outlines the systematic sequence to close the entire backlog, starting immediately with **Slice 1: Phase C5 (`/api/scan`) and the Transcode Start shim**.

---

## 2. Overall Backlog Retirement Roadmap

| Slice | Scope | Dependencies | Status |
|---|---|---|---|
| **Slice 1** | **Phase C5 (`/api/scan`) + `POST /api/transcode/start` shim + Probe tightening** | None (self-contained) | **Ready to Implement** |
| **Slice 2** | **Phase C3b (`GET /api/devices`, `/rename`, `/delete`)** | Admin auth / PIN | Up next |
| **Slice 3** | **Storage (`/api/storage/*` retention, audit, purge)** | Admin auth / PIN | Up next |
| **Slice 4** | **Auth & Admin (`/auth/*`, `/api/auth/*`, `/api/admin/*`)** | `docs/AUTHENTICATION_PLAN.md` | Final bridge removal |
| **Slice 5** | **Phase 6C Transcode Worker + Port Cutover (`:8001` → `:8000`)** | All routes native | Completion |

---

## 3. Slice 1 Detailed Specification

### 3.1 Native Library Scan Endpoint (`/api/scan`)

#### A. Route Contract & Admin Gate
- **Methods:** `GET` and `POST` (matching Flask `app/routes/api.py:109`).
- **Authorization on `POST`:**
  - Must enforce administrator verification:
    1. Read configured `admin_pin` from PostgreSQL `settings` table (`SELECT value FROM settings WHERE key = 'admin_pin'`).
    2. Check `X-Admin-Pin` header (and JSON body `{ "admin_pin": "..." }`).
    3. If `admin_pin` in database is unset/empty, the gate **fails closed** (no hardcoded PIN, no query param accepted per `AGENTS.md` §4).
    4. If unauthorized, return HTTP **403 Forbidden**:
       ```json
       { "error": "Administrator verification required to trigger library scan." }
       ```
- **Authorization on `GET`:**
  - Non-gated, returns current scan status / triggers scan (matching Flask behavior).

#### B. Execution & Concurrency
- **Concurrency Guard:** An in-process `AtomicBool` (`SCANNER_BUSY`) prevents overlapping execution. If a scan is already running, subsequent triggers do not spawn additional processes.
- **Scan Trigger:**
  - Asynchronously spawns the ingestion scanner via `tokio::process::Command` using the virtualenv Python (`venv/Scripts/python.exe scanner.py`) with `MEDIA_SERVER_BASE_DIR` set.
  - Queries `JobService` or media directories for missing transcodes to populate transcode counts.
- **Response Shape (HTTP 200):**
  ```json
  {
    "busy": false,
    "status": "scanning",
    "transcodes_queued": 0,
    "transcodes_started": 0,
    "transcodes_skipped": 0,
    "transcodes_errors": 0
  }
  ```

### 3.2 Transcode Start Compatibility Shim (`POST /api/transcode/start/{*filename}`)

#### A. Route Contract
- **Method:** `POST /api/transcode/start/{*filename}`
- **Behavior:**
  - Path-decode percent-encoded filename (e.g., spaces, brackets).
  - Verify filename exists in media roots and represents a valid video format (`.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`).
  - If invalid or nonexistent: Return **HTTP 404** (matching Flask abort 404).
  - If direct-play / already transcoded: Return HTTP 200 `{"status": "ready", "message": "Direct playable media does not require transcoding"}`.
  - If requires transcode: Delegate to `JobService::enqueue(&pool, &filename, "hls", false)`.
  - Return HTTP 200 with JSON:
    ```json
    {
      "status": "queued",
      "message": "Transcoding started in background"
    }
    ```

### 3.3 Probe Tightening (`scripts/probe_android_api.py`)
- Remove permissive `404` acceptance for `POST /api/scan` and `POST /api/transcode/start`.
- Assert strict status codes:
  - `POST /api/scan`: `(200, 401, 403)` (403 when unauthenticated, 404 disallowed).
  - `POST /api/transcode/start/...` with synthetic file: `(404,)` (strictly verifies that the route handles the nonexistent file, not a route missing 404).

### 3.4 Proxy Mount Removal
- Remove `.route("/api/scan", axum::routing::any(routes::proxy::proxy_handler))` from `rust/src/lib.rs:343`.
- Proxy route groups reduced from 6 to 5.

---

## 4. Scope

### In Scope for Slice 1
- `rust/src/routes/scan.rs` (new route handler for `/api/scan`).
- `rust/src/services/scan_service.rs` (new scan management & process supervision service).
- `rust/src/routes/transcode.rs` or `rust/src/routes/jobs.rs` (add `/api/transcode/start/{*filename}` shim).
- `rust/src/lib.rs` (mount native scan and transcode-start routes, remove `/api/scan` proxy mount).
- `rust/tests/scan_test.rs` & `rust/tests/transcode_start_test.rs` (comprehensive unit/contract tests).
- `scripts/probe_android_api.py` (tighten contract validation).

### Explicitly Deferred to Slices 2–4
- `/api/devices` (C3b list/rename/delete).
- `/api/storage/*` (storage retention, pool audit/purge).
- `/auth/*`, `/api/auth/*`, and `/api/admin/*` (full Google OAuth & Admin PIN management).
- Port swap (`:8001` → `:8000`).

---

## 5. Exit Criteria (Verifiable)

1. **Native `/api/scan` Verification:**
   - Unauthenticated `POST /api/scan` returns `403 Forbidden` on `:8001`.
   - `POST /api/scan` with header `X-Admin-Pin: <valid_pin>` returns `200 OK` with JSON `{ "status": "scanning", "busy": true/false, ... }`.
   - `GET /api/scan` returns `200 OK` with scan status JSON.
2. **Native `/api/transcode/start` Verification:**
   - `POST /api/transcode/start/nonexistent_file.mkv` returns `404 Not Found`.
   - `POST /api/transcode/start/<valid_sample_file>` returns `200 OK` and creates/returns job in `transcode_jobs` table.
3. **Proxy Cleanup:**
   - `/api/scan` is deleted from `rust/src/lib.rs` proxy block; proxy groups drop from 6 to 5.
4. **Probe & Suite Health:**
   - `scripts/probe_android_api.py --base http://127.0.0.1:8001` passes 22/22 with tightened status expectations.
   - `scripts/probe_android_api.py --base http://127.0.0.1:8000` passes 22/22.
   - Rust test suite passes with 0 failures (expected 230+ passing tests).

---

## 6. Risks and Safety Guardrails

| Risk | Mitigation |
|---|---|
| **Security Leak on Admin PIN** | Never accept PIN from query string (`?pin=`). Accept only from `X-Admin-Pin` header or JSON body. Fail closed if `admin_pin` is unset in database. |
| **Process Storm / Concurrency** | Use `AtomicBool` scan lock in Rust to ensure concurrent requests return current status without spawning multiple parallel scanner processes. |
| **Library Mutation During Test** | Use mocked/isolated tests for unit tests. For live verification, snapshot database `movies` rows before/after to guarantee zero unintended record deletion. |
| **Radix Router Conflict in Axum** | Ensure path parameter routing for `/api/transcode/start/{*filename}` does not collide with existing prefixes. |

---

## 7. Open Decisions for User Confirmation

1. **Slice 1 Execution**: Do you approve beginning implementation with Slice 1 (Phase C5 native `/api/scan` + `/api/transcode/start` shim + probe tightening)?
2. **Subsequent Cadence**: Should we proceed sequentially from Slice 1 through Slices 2–4 to completely eliminate all 6 bridge groups before initiating the port swap?
