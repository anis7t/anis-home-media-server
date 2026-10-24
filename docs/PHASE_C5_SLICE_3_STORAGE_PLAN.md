# Phase C5 Slice 3 — Storage Management & Cache Purge Parity (`/api/storage/*`) Implementation Plan

**Date:** 2026-10-16  
**Target Branch:** `feat/rust-transcode-worker`  
**Prerequisites:** Phase C5 Slice 1 (`68538e1`) and Slice 2 (`1a30efd`) complete & committed  
**Objective:** Port the storage management and cache retention surface natively to Rust Axum, eliminate the `/api/storage/*` reverse-proxy bridge group from `rust/src/lib.rs`, enforce fail-closed admin authorization semantics, and ensure 100% parity with the React SPA storage pool dashboard.

---

## 1. Background & Current State

The media server maintains two cache pools on drive `E:`:
1. `cache/hls`: Completed and in-progress multi-GPU HLS streams.
2. `cache/previews`: Seek-hover frame thumbnail grids and VTT storyboards.

In Flask, storage retention policies (`keep`, `archive`, `purge_cache`) are persisted in the `settings` database table, and cache reconciliation (`audit_orphaned_caches` and `purge_orphaned_caches`) is managed by `app/services/transcode_service.py`.

Currently, in `rust/src/lib.rs`, the entire storage route namespace is forwarded to Flask `:8000` via the reverse-proxy bridge:
```rust
.route("/api/storage", axum::routing::any(routes::proxy::proxy_handler))
.route("/api/storage/{*path}", axum::routing::any(routes::proxy::proxy_handler))
```

Porting these endpoints natively will eliminate `/api/storage/*` from the proxy bridge, reducing the remaining reverse-proxy bridge groups from 4 down to 3 (`/auth/*`, `/api/auth/*`, `/api/admin/*`).

---

## 2. Technical Specifications & Endpoints

### 2.1 `GET /api/storage/audit`
- **Authorization**: Protected by `@require_admin` (requires valid `X-Admin-Pin` header or body pin via `AuthService::is_admin_authorized`).
- **Functionality**:
  1. Inspects `cache/hls` and `cache/previews` subdirectories.
  2. Queries `movies` table in PostgreSQL to match cache directories against known titles.
  3. Queries `transcode_jobs` table to identify in-progress or queued jobs.
  4. Classifies cache folders as:
     - `active`: Matches a known movie or active transcode job.
     - `orphaned`: Cache directory exists on disk but has no corresponding row in `movies` and is not part of an active transcode job.
  5. Measures disk consumption (`bytes`) for active vs orphaned caches.
  6. Combines cache audit data with pool telemetry from `SystemService::get_storage_telemetry`.
- **Response Shape**:
  ```json
  {
    "storage": {
      "total_bytes": 1000000000,
      "used_bytes": 500000000,
      "free_bytes": 500000000,
      "percent_used": 50.0
    },
    "audit": {
      "hls_active_bytes": 100000,
      "hls_orphaned_bytes": 0,
      "preview_active_bytes": 50000,
      "preview_orphaned_bytes": 0,
      "orphaned_directories": []
    }
  }
  ```

### 2.2 `POST /api/storage/purge-orphans`
- **Authorization**: Protected by `@require_admin` (via `AuthService::is_admin_authorized`).
- **Functionality**:
  1. Accepts `dry_run` flag (via query `?dry_run=1` or JSON body `{"dry_run": true}`).
  2. Guardrail check: Queries `transcode_jobs` to verify whether an active transcoding job is running. If an active transcode is running, refuses the purge request (`refused: true, reason: "Transcode in progress"`).
  3. Identifies all verified orphaned cache directories (modified > 30 minutes ago to avoid deleting scratch directories of newly enqueued work).
  4. If `dry_run == true`: returns the list of directories and bytes that would be deleted without touching disk.
  5. If `dry_run == false`: safely deletes orphaned directories and reclaims disk space.
- **Response Shape**:
  ```json
  {
    "success": true,
    "result": {
      "dry_run": false,
      "purged_directories": [],
      "bytes_reclaimed": 0,
      "errors": []
    }
  }
  ```

### 2.3 `GET /api/storage/settings` & `POST /api/storage/settings`
- **`GET /api/storage/settings`**:
  - Non-gated read of current storage retention policy.
  - Queries `settings` table: `SELECT value FROM settings WHERE key = 'retention_policy'`. Defaults to `"keep"`.
  - Returns:
    ```json
    {
      "retention_policy": "keep",
      "allowed_policies": ["archive", "keep", "purge_cache"],
      "archive_dir": "D:\\Flicks\\.archive"
    }
    ```
- **`POST /api/storage/settings`**:
  - Gated by `AuthService::is_admin_authorized`.
  - Body: `{"retention_policy": "archive" | "keep" | "purge_cache", "admin_pin": Option<String>}`.
  - Validates that `retention_policy` is one of `keep`, `archive`, `purge_cache`. Returns 400 if invalid.
  - Upserts into `settings`: `INSERT INTO settings (key, value) VALUES ('retention_policy', $1) ON CONFLICT (key) DO UPDATE SET value = $1`.
  - Returns 200 `{"success": true, "retention_policy": policy}`.

### 2.4 `POST /api/storage/archive/{*filename}`
- **Authorization**: Gated by `AuthService::is_admin_authorized`.
- **Functionality**:
  1. Decodes `filename` and resolves the original media path across configured `media_roots`. Returns 404 if not found.
  2. Verifies that HLS transcoding for this movie is complete by checking for `#EXT-X-ENDLIST` in `cache/hls/{relative_stem}/master.m3u8` or playlist.
  3. Moves original media file to `ARCHIVE_DIR` (e.g. `D:\Flicks\.archive\{filename}`).
  4. Updates database `movies` row if path references need updating.
  5. Returns 200 `{"success": true, "result": {"status": "archived", "archived_path": "..."}}`.

---

## 3. Scope

### In Scope for Slice 3
- **`rust/src/services/storage_service.rs`**: Native storage audit, orphaned cache resolution, purge execution, retention policy management, and archive relocation service.
- **`rust/src/routes/storage.rs`**: Route handlers for audit, purge-orphans, settings, and archive.
- **`rust/src/lib.rs`**:
  - Mount native `storage_routes`.
  - Delete `/api/storage` and `/api/storage/{*path}` from `proxy_routes`.
- **`rust/tests/storage_test.rs`**: Comprehensive test suite verifying:
  - `GET /api/storage/settings` returns current policy.
  - `POST /api/storage/settings` rejects unauthenticated requests with 403, rejects invalid policy with 400, succeeds with admin PIN.
  - `GET /api/storage/audit` returns active vs orphaned telemetry.
  - `POST /api/storage/purge-orphans` supports dry run and deletes verified orphaned folders without deleting active movie caches.
- Verify full test battery (`cargo test`) and probe (`scripts/probe_android_api.py`).

### Deliberately Out of Scope
- `/auth/*` and `/api/auth/*` (Session tokens & Google OAuth - deferred to Slice 4).
- `/api/admin/*` (Google admin sessions & PIN status/change - deferred to Slice 4).
- Production port swap (`:8001` -> `:8000`).

---

## 4. Exit Criteria

1. **Native Parity**:
   - `GET /api/storage/audit` returns valid JSON with `storage` and `audit` objects matching Flask.
   - `POST /api/storage/purge-orphans` refuses purge if a transcode job is active, supports dry run, and purges orphaned directories.
   - `GET /api/storage/settings` and `POST /api/storage/settings` manage retention policy.
   - `POST /api/storage/archive/{*filename}` safely moves completed media to archive directory.
2. **Security & Authorization Invariants**:
   - Destructive routes (`purge-orphans`, `settings` POST, `archive` POST) fail closed if unauthenticated (HTTP 403).
   - Admin credentials verified strictly via `X-Admin-Pin` header or body `admin_pin`.
3. **Proxy Group Elimination**:
   - `/api/storage` and `/api/storage/{*path}` removed from `lib.rs` proxy block.
   - Remaining proxy groups reduced to 3 (`/auth/*`, `/api/auth/*`, `/api/admin/*`).
4. **Automated Verification**:
   - All tests in `rust/tests/storage_test.rs` pass.
   - Repository-wide test suite passes with 0 failures (245+ tests).
   - `scripts/probe_android_api.py` passes 22/22 on both `:8000` and `:8001`.

---

## 5. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| **Accidental Deletion of Active Cache** | Cross-check all directories against both the `movies` table and `transcode_jobs` active rows before classifying as orphaned. Apply a 30-minute mtime threshold. |
| **Purge During Active Transcode** | Guardrail check: if `JobService::has_active_jobs(&pool)` is true, immediately return `refused: true` with HTTP 200 (matching Flask). |
| **Cross-Volume File Move on Windows** | In `archive_media`, use robust cross-volume file relocation (copy + delete if rename fails with cross-device link error `EXDEV`). |

---

## 6. Open Decisions for User Confirmation

1. **Orphan Purge Age Threshold**:
   - Should cache directories be at least 30 minutes old before being eligible for orphaned purge to guarantee safety against in-flight job creation? *(Recommended: Yes, 30 minutes)*
2. **Archive Safety Check**:
   - Should manual archive strictly require `#EXT-X-ENDLIST` in the HLS playlist before moving the source file to `.archive`? *(Recommended: Yes)*
