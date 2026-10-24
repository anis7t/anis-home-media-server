# Walkthrough — Storage Audit Timeout & Library Scan Reliability Fixes

**Release:** v1.3.2 (Build 145)  
**Date:** October 25, 2026  
**Status:** ✅ Completed & Verified on Physical Device (`192.168.1.6:40283`)

---

## 1. Problem Statements & Root Causes

### Issue A: Storage & Retention Audit Timeout in Admin Hub
- **Symptom:** Opening **Admin Management Hub → Storage & Retention** failed with:
  ```text
  DioExceptionType.receiveTimeout: The request connection took longer than 5000ms and was aborted
  ```
- **Root Cause:**
  - The server cache directory (`cache/hls` and `cache/previews`) contains **162,298 files** across 34 active video streams.
  - Calling `GET /api/storage/audit` performed synchronous directory walks and `fs::metadata()` queries across all 162k files on Windows NTFS, taking **17.658 seconds** on cold execution.
  - In `flutter_client`, `ApiClient` had hardcoded `receiveTimeout: const Duration(seconds: 5)`, meaning the HTTP client severed the connection at 5,000ms every time, triggering a timeout exception.

### Issue B: Home Screen Library Scan Button Intermittent Failure
- **Symptom:** Tapping the top-right refresh/scan button on the Home screen would report "Failed to trigger library scan" even when the server actually started scanning.
- **Root Cause:**
  - In `LibraryController.triggerScan()`, the API trigger call was directly coupled with `await loadLibrary(isRefresh: true)`.
  - When the server began scanning (holding database connections/locks or consuming background I/O), the immediate follow-up `loadLibrary` query either took >5s or timed out.
  - The overarching `catch (e)` in `triggerScan()` caught that secondary reload failure and returned `false`, erroneously reporting that the scan trigger failed.
  - In `LibraryRepository.triggerScan()`, the method only accepted HTTP 200, but background operations can return HTTP 202 Accepted.

---

## 2. Changes Made

### A. Backend Architecture & Caching (`rust/`)

1. **In-Memory TTL Cache for Storage Audit (`rust/src/services/storage_service.rs`):**
   - Added `AUDIT_CACHE: RwLock<Option<(Instant, StorageAuditResponse)>>` with a 60-second TTL (`AUDIT_CACHE_TTL`).
   - `audit_caches(force_refresh: bool)` returns the cached audit response in **<10 milliseconds** if valid and not forced.
   - Added `invalidate_audit_cache()` which clears the cached audit whenever caches are purged via `purge_orphaned_caches`.

2. **O(1) Video Path Lookup in Transcode Engine (`rust/src/services/storage_service.rs`):**
   - Converted `walk_videos` lookup from $O(N^2)$ `Vec::contains` to $O(1)$ `HashSet<PathBuf>`.

3. **HTTP Query Parameter Support (`rust/src/routes/storage.rs`):**
   - Updated `storage_audit_handler` to accept `?force=true` or `?force=1` for manual cache bypass.
   - Wired `StorageService::invalidate_audit_cache()` to execute immediately when `storage_purge_orphans_handler` runs.

### B. Client Timeout & Decoupled State Management (`flutter_client/`)

1. **Global Timeout Extension (`flutter_client/lib/core/api/api_client.dart`):**
   - Increased default network timeouts to handle multi-drive disk operations:
     - `connectTimeout`: 5s → **15s**
     - `receiveTimeout`: 5s → **30s**
     - `sendTimeout`: 5s → **30s**

2. **Dedicated Heavy Endpoint Timeouts (`flutter_client/lib/features/admin/infrastructure/admin_repository.dart`):**
   - Attached dedicated `Options(receiveTimeout: const Duration(seconds: 60))` to:
     - `getStorageAudit({bool force = false})`
     - `purgeOrphanedCaches()`
     - `triggerScan()`

3. **Decoupled Library Scan Trigger (`flutter_client/lib/features/library/`):**
   - In `library_repository.dart`: Configured 60s timeout and accepted HTTP 200 and HTTP 202.
   - In `library_controller.dart`: Separated the scan trigger from the catalog refresh:
     ```dart
     final success = await _repository.triggerScan();
     if (success) {
       unawaited(loadLibrary(isRefresh: true).catchError((e, st) {
         _logger.w('Post-scan reload deferred: $e');
       }));
       return true;
     }
     ```
   - In `home_screen.dart`: Updated user feedback to display informative messages.

---

## 3. Verification & Test Outcomes

### A. Backend Performance & Contract Validation
- **Cold vs Cached Latency:**
  - Cold audit (first call): 25.9 seconds (walked 162,298 files).
  - Cached audit (subsequent calls): **0.0095 seconds (9.5 ms) — a 2,700× speedup!**
- **Android API Contract Probe:**
  - Executed `scripts/probe_android_api.py`: **22 / 22 endpoints passed (100% OK)**.

### B. Flutter Static Analysis & Unit Tests
- `flutter analyze`: **0 warnings, 0 errors**.
- Test Suites (`admin_controllers_test.dart`, `admin_hub_screen_test.dart`, `library_controller_test.dart`): **72 / 72 tests passed**.

### C. Physical Android Phone ADB Verification (`192.168.1.6:40283`)
- Built and published **Release APK v1.3.2 (Build 145)** via `scripts/release_android.py`.
- Installed onto the user's phone via `adb install -r updates/production/media-server-client.apk`.
- **Live Test 1 (Storage & Retention):**
  - Navigated to `Admin Management Hub → Storage & Retention`.
  - Audited storage pool rendered instantly without timeouts:
    - Mass Storage (`D:`): 86.7% • 124.0 GB free
    - Fast SSD (`E:`): 90.2% • 23.4 GB free
    - Active Caches: 148.6 GB (34 streams)
    - Orphaned Caches: 0 B
- **Live Test 2 (Home Scan Button):**
  - Tapped the sync button on the Home screen header.
  - Toast displayed: **"Library scan started successfully"** with green background.
  - Top right sync spinner animated while the scan executed in the background.

---

## 4. Deliverables & Modified Files

- [storage_service.rs](file:///E:/MediaServer/rust/src/services/storage_service.rs)
- [storage.rs](file:///E:/MediaServer/rust/src/routes/storage.rs)
- [api_client.dart](file:///E:/MediaServer/flutter_client/lib/core/api/api_client.dart)
- [admin_repository.dart](file:///E:/MediaServer/flutter_client/lib/features/admin/infrastructure/admin_repository.dart)
- [storage_controller.dart](file:///E:/MediaServer/flutter_client/lib/features/admin/presentation/controllers/storage_controller.dart)
- [library_repository.dart](file:///E:/MediaServer/flutter_client/lib/features/library/data/repositories/library_repository.dart)
- [library_controller.dart](file:///E:/MediaServer/flutter_client/lib/features/library/presentation/controllers/library_controller.dart)
- [home_screen.dart](file:///E:/MediaServer/flutter_client/lib/features/home/presentation/screens/home_screen.dart)
- [version_registry.json](file:///E:/MediaServer/updates/version_registry.json)
