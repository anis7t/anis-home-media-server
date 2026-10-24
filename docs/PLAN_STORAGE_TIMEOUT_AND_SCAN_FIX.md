# Implementation Plan: Storage & Retention Timeout and Home Scan Failure Fix

**Date:** 2026-10-25  
**Working Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Target Release:** Android Production v1.3.2 (Build 145) + Rust Backend Hotfix  

---

## 1. Problem Statement & Root Cause Analysis

### A. Storage & Retention Timeout in Admin Management
- **Symptom:** Opening the Storage & Retention tab in Admin Management consistently fails with `Connection timed out` or `Server error: timeout`.
- **Root Cause:**
  1. **NTFS Metadata Overhead on 162K Cache Files:** `StorageService::audit_caches` recursively walks `cache/hls` and `cache/previews` calling `fs::metadata()` on every single `.m4s` segment and `.jpg` preview thumbnail. The live cache currently contains **162,298 files**. Executing 162,298 synchronous Windows filesystem metadata syscalls inside the Tokio async worker thread took **17.658 seconds** in measurement.
  2. **Aggressive Client Timeout:** In `flutter_client/lib/core/api/api_client.dart`, `receiveTimeout` was configured to **5.0 seconds**. Because the backend takes ~17.6 seconds, Dio aborts the HTTP connection after exactly 5000ms every time.

### B. Home Screen Library Scan Button Failure
- **Symptom:** Tapping the sync/scan button in the top right of the Home screen sometimes displays `Failed to trigger library scan`.
- **Root Cause:**
  1. **Coupled Refresh in `LibraryController.triggerScan()`:** `LibraryController` runs `await _repository.triggerScan()`. If successful, it runs `await loadLibrary(isRefresh: true)`. If `loadLibrary` times out or encounters network latency while the server is busy starting the scan, the error is caught by `catch (e)`, which discards the scan trigger success and returns `false`.
  2. **Unclear User Feedback:** Home screen displays a generic "Failed to trigger library scan" even if the scan was already actively running or if authentication was missing.

---

## 2. Proposed Architecture & Implementation

### Phase 1: Backend Optimization & Caching (`rust/src/services/storage_service.rs` & `rust/src/routes/storage.rs`)
1. **In-Memory TTL Caching for Storage Audit:**
   - Store the latest `StorageAuditResponse` in an `Arc<RwLock<Option<(Instant, StorageAuditResponse)>>>` with a 60-second TTL.
   - Subsequent calls within 60 seconds return instantly (<1ms).
   - Invalidate cache immediately when `purge_orphaned_caches` executes.
   - Support `?force=true` query parameter for explicit user pull-to-refresh.
2. **Asynchronous Non-Blocking Execution:**
   - Wrap cold disk auditing inside `tokio::task::spawn_blocking` to prevent Tokio reactor thread starvation.
3. **Linear Algorithmic Optimization:**
   - Replace O(N^2) `Vec::contains(&p)` in `walk_videos` with a `HashSet<PathBuf>`.

### Phase 2: Frontend Network Timeout & Resiliency Hardening (`flutter_client/`)
1. **Extend Global & Admin Timeouts (`lib/core/api/api_client.dart` & `lib/features/admin/infrastructure/admin_repository.dart`):**
   - Increase default timeouts in `ApiClient`: `connectTimeout: 15s`, `receiveTimeout: 30s`, `sendTimeout: 30s` (up from 5s).
   - In `AdminRepository`, specify dedicated `Options(receiveTimeout: const Duration(seconds: 60))` for disk-intensive operations (`getStorageAudit()`, `purgeOrphanedCaches()`, `triggerScan()`).
2. **Decouple Post-Scan Library Refresh (`lib/features/library/presentation/controllers/library_controller.dart`):**
   - When `_repository.triggerScan()` returns true, trigger `loadLibrary(isRefresh: true)` asynchronously in the background (`unawaited` / `catchError`) so that secondary catalog queries do not retroactively invalidate a successful scan trigger.
3. **Enhanced Home Scan Feedback (`lib/features/home/presentation/screens/home_screen.dart`):**
   - Improve scan action feedback to distinguish between scan queued, already running, and network issues.

### Phase 3: Verification, Release & On-Device Testing
1. Recompile release Rust binary with `scripts\cargo.bat build --release`, stop and restart `MediaServerRust` Windows service.
2. Verify `GET /api/storage/audit` latency via curl (<5ms on cache hit).
3. Run `flutter analyze` and Flutter test suites.
4. Build and publish Production APK v1.3.2 (Build 145) via `scripts/release_android.py`.
5. Install on connected phone (`192.168.1.6:40283`) via ADB and test:
   - Opening Storage & Retention in Admin Management (verifying instant load and zero timeout).
   - Tapping the Home screen scan button (verifying reliable trigger).

---

## 3. Scope & Non-Goals

- **In Scope:** `StorageService` audit cache & worker offloading, `ApiClient` timeouts, `AdminRepository` options, `LibraryController` decoupled refresh, Home scan feedback, APK v1.3.2 release.
- **Out of Scope:** Changing the HLS chunking format or deleting active transcodes.

---

## 4. Exit Criteria

- [ ] `GET /api/storage/audit` returns in <10ms for cached hits and does not block Tokio worker threads when cold.
- [ ] Admin Management -> Storage & Retention loads on the Android mobile client without timeouts.
- [ ] Home menu scan button triggers reliably without false-negative failures.
- [ ] All Flutter unit and widget tests pass.
- [ ] `flutter analyze` reports 0 issues.
- [ ] APK v1.3.2 (Build 145) built, published, and verified on physical phone via ADB.

---

## 5. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| 60s cache shows slightly stale size after purge | Invalidate the cache immediately upon executing `purge_orphaned_caches`. |
| Locked Windows service binary during compile | Stop `MediaServerRust` via elevated script, compile with `scripts\cargo.bat`, restart service. |
