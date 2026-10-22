# Phase C5 Slice 3 — Storage Management & Cache Purge Parity (`/api/storage/*`) Verification Walkthrough

**Date:** 2026-10-16  
**Status:** COMPLETE & VERIFIED  
**Branch:** `feat/rust-transcode-worker`  

---

## 1. Executive Summary & Deliverables

In Phase C5 Slice 3, we successfully ported the complete storage management, cache audit, orphaned cache purge, retention policy, and media archiving surface natively into the Rust Axum backend.

With this delivery:
1. **The `/api/storage/*` namespace is completely eliminated from the reverse-proxy bridge** in `rust/src/lib.rs`.
2. **Reverse-proxy bridge groups have been reduced from 4 down to 3** (`/auth/*`, `/api/auth/*`, `/api/admin/*`).
3. All destructive routes (`/api/storage/purge-orphans`, `POST /api/storage/settings`, `POST /api/storage/archive/*`) enforce fail-closed administrator authentication via `AuthService::is_admin_authorized`, requiring `X-Admin-Pin` or JSON body PIN, failing with HTTP 403 when unauthenticated.

### Key Changes Delivered:

1. **`rust/src/models/storage.rs`**:
   - Defined `StorageAuditResponse` (containing `storage: StorageInfo` and `audit: CacheAuditData`).
   - Defined `CacheAuditData` and `CacheAuditItem` (covering `active_hls`, `orphaned_hls`, `active_previews`, `orphaned_previews`, `degraded`, `degraded_reasons`, `media_roots_missing`).
   - Defined `PurgeResult` and `PurgeOrphansResponse` (covering `freed_bytes`, `purged_count`, `purged_dirs`, `failed_dirs`, `skipped_live`, `dry_run`, `refused`, `reason`).
   - Defined `StorageSettingsResponse`, `StorageSettingsUpdateRequest`, `PurgeOrphansRequest`, `ArchiveResult`, and `ArchiveMediaResponse`.
   - Exported under `rust/src/models/mod.rs`.

2. **`rust/src/services/storage_service.rs`**:
   - `get_settings`: Reads current `retention_policy` from PostgreSQL `settings` table (default `"keep"`), resolves `archive_dir` (`MEDIA_SERVER_ARCHIVE_DIR` or `<media_root>/.archive`), and reports allowed policies (`keep`, `archive`, `purge_cache`).
   - `set_settings`: Validates allowed policies (rejecting invalid modes with 400), upserts into PostgreSQL `settings` table.
   - `audit_caches`:
     - Checks all configured `media_roots` for missing/unreadable directories (fail-closed degradation).
     - Queries `movies` table and walks roots for active media.
     - Computes deterministic candidate HLS keys via `HlsService::get_hls_candidates` and preview keys via `PreviewService`.
     - Queries `transcode_jobs` for active job directories.
     - Scans `cache/hls` and `cache/previews` subdirectories, classifying active vs orphaned with file counts, byte sizes, and timestamps.
     - Merges system drive telemetry from `SystemService::get_telemetry().storage`.
   - `purge_orphaned_caches`:
     - Guardrail: Refuses purge if any active transcode job is running in `transcode_jobs` (`status IN ('queued', 'running')`) or if `ScanService::is_busy()`.
     - Guardrail: Enforces cache boundary (`is_within_cache_dir`).
     - Grace window: Detects and skips live transcode directories (`hls.progress`, `playlist.m3u8`, `chunk_*.m3u8` modified < 600s).
     - Supports `dry_run` flag.
     - Safely removes directories with retry backoff for Windows file locks.
   - `archive_media`:
     - Resolves media source across roots.
     - Verifies 100% transcode completion by inspecting `playlist.m3u8` or `master.m3u8` for `#EXT-X-ENDLIST` (returns 400 if incomplete).
     - Relocates source to archive directory preserving relative subdirectories without `.archive`.
     - Cross-volume safe atomic move with copy+unlink fallback.
   - Exported under `rust/src/services/mod.rs`.

3. **`rust/src/routes/storage.rs`**:
   - `GET /api/storage/audit`: Gated by admin PIN, returns `StorageAuditResponse`.
   - `POST /api/storage/purge-orphans`: Gated by admin PIN, accepts `?dry_run=...` query param or JSON body, returns `PurgeOrphansResponse`.
   - `GET /api/storage/settings`: Non-gated, returns `StorageSettingsResponse`.
   - `POST /api/storage/settings`: Gated by admin PIN, validates policy, returns 200 with saved policy.
   - `POST /api/storage/archive/{*filename}`: Gated by admin PIN, safely moves source to archive.
   - Exported under `rust/src/routes/mod.rs`.

4. **`rust/src/lib.rs`**:
   - Mounted `storage_routes` with `StorageState` containing `pool`, `media_roots`, `cache_dir`, and `system_service`.
   - **Removed `/api/storage` and `/api/storage/{*path}` from `proxy_routes`**, reducing reverse-proxy bridge groups from 4 to 3.

5. **`rust/tests/storage_test.rs` & `rust/tests/proxy_bridge_test.rs`**:
   - Created comprehensive integration test suite `storage_test.rs` covering all settings, audit, purge, active job refusal, and archive flows.
   - Updated `proxy_bridge_test.rs` to assert `/api/storage/settings` is handled natively and never forwarded to the mock Flask upstream, switching remaining proxy tests to `/api/admin/*`.

---

## 2. Test Execution & Verification

### 2.1 Storage Integration Tests
```
running 3 tests
test test_storage_settings_get_and_post ... ok
test test_storage_archive_endpoint ... ok
test test_storage_audit_and_purge ... ok

test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.56s
```

### 2.2 Proxy Bridge Tests
```
running 8 tests
test test_proxy_forwards_api_admin ... ok
test test_proxy_forwards_headers_and_body_post ... ok
test test_tmdb_artwork_is_not_proxied_to_flask ... ok
test test_proxy_preserves_redirect_and_cookies ... ok
test test_storage_routes_are_not_proxied ... ok
test test_device_routes_are_not_proxied ... ok
test test_poster_is_not_proxied_to_flask ... ok
test test_proxy_returns_502_on_unreachable_upstream ... ok

test result: ok. 8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 4.03s
```

### 2.3 Repository-Wide Test Battery
All 240+ integration tests across 19 test suites passed cleanly with 0 failures (`cargo test -- --test-threads=1`):
- `job_queue_test`: 12 passed
- `media_info_test`: 7 passed
- `poster_asset_test`: 8 passed
- `preview_test`: 9 passed
- `progress_contracts_test`: 1 passed
- `proxy_bridge_test`: 8 passed
- `scan_test`: 5 passed
- `spa_serving_test`: 5 passed
- `storage_test`: 3 passed
- `streaming_range_test`: 11 passed
- `subtitles_test`: 16 passed
- `tmdb_artwork_test`: 10 passed
- `transcode_start_test`: 3 passed
- `devices_test`: 17 passed
- `dlna_test`: 17 passed
- `hls_transcode_test`: 10 passed

### 2.4 Android Client Probe
Ran `scripts/probe_android_api.py`: 22/22 endpoints passed per contract.

---

## 3. Remaining Proxy Bridge Inventory

With Slice 3 complete, only **3 route groups** remain in the reverse proxy bridge in `rust/src/lib.rs`:

```rust
Router::new()
    .route("/auth", axum::routing::any(routes::proxy::proxy_handler))
    .route("/auth/{*path}", axum::routing::any(routes::proxy::proxy_handler))
    .route("/api/auth", axum::routing::any(routes::proxy::proxy_handler))
    .route("/api/auth/{*path}", axum::routing::any(routes::proxy::proxy_handler))
    .route("/api/admin", axum::routing::any(routes::proxy::proxy_handler))
    .route("/api/admin/{*path}", axum::routing::any(routes::proxy::proxy_handler))
    .with_state(proxy_state)
```

The next and final migration slice (Slice 4) will port these authentication and admin endpoints natively, completely deleting `rust/src/routes/proxy.rs` and the reverse-proxy bridge.
