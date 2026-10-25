# Implementation Plan — Phase 12 Slice 12.4: Native Admin Management Hub in Mobile & TV Settings

**Document Version:** 1.0  
**Date:** 2026-10-24  
**Author:** Antigravity  
**Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Targets:** Flutter Client (`flutter_client/` — Android Phone & Android TV / Fire TV) + Rust Axum Backend (`rust/`)

---

## 1. Executive Summary & Scope

### In Scope
1. **Admin Hub Access & Entry Point in Settings:**
   - Embed an "Admin & Server Management" entry card in `SettingsScreen` (Phone: touch card; TV: D-pad focusable tile).
   - Role-gated: If user is authenticated as `Admin`, opens the Hub directly. If Guest or Viewer, prompts for Admin PIN (via `AdminPinSheet` on Phone or `TvAdminPinPad` on TV) and transitions into the Hub upon success.
2. **Storage Telemetry & Retention Management (`/api/storage/*`, `/api/system-status`):**
   - Dual-drive Storage Pool HUD displaying Drive `D:` (Media Storage) and Drive `E:` (App, Cache, SSD scratch) capacity, free space, and headroom.
   - Retention policy picker (`keep`, `archive`, `purge_cache`) backed by `GET /api/storage/settings` and `POST /api/storage/settings`.
   - Cache audit card (`GET /api/storage/audit`) reporting active vs orphaned HLS and preview caches.
   - "Purge Orphaned Caches" action (`POST /api/storage/purge-orphans`) with confirmation modal.
3. **Transcode Dashboard & Dual-GPU Telemetry (`/api/transcode/*`, `/api/jobs/*`):**
   - Dual-GPU status HUD for AMD Radeon RX 560X (Discrete) and AMD Radeon Vega 8 (Integrated).
   - Active transcode jobs rail/list showing title, poster, quality tier, speed, fps, ETA, chunk progress bar, and "Cancel" action (`POST /api/transcode/jobs/{filename}/cancel`).
   - Recent jobs history list and "Sweep Inactive Jobs" action (`POST /api/transcode/sweep`).
4. **Connected Devices Management (`/api/devices/*`):**
   - Live list of registered clients (`GET /api/devices`) with active (🟢), idle (🟡), and offline (⚪) status chips.
   - Device cards displaying client hardware model, OS version, IP, network path (LAN / Cloudflare Tunnel / WAN), and last seen time.
   - Device actions: Friendly renaming modal (`POST /api/devices/rename`) and Revoke/Forget device (`POST /api/devices/delete`).
5. **Library Maintenance & Security Tools (`/api/scan/*`, `/api/admin/*`):**
   - Manual TMDb Library Scan trigger (`POST /api/scan`) with live scanning spinner and status banner (`GET /api/scan`).
   - Admin PIN Rotation sheet/modal (`POST /api/admin/pin`).
   - Security Audit Logs viewer (`GET /api/admin/audit-logs`) with actor, action, timestamp, and details.
6. **Testing & Parity:**
   - Unit tests for all domain models and JSON serialization.
   - Repository and controller tests for all admin capabilities.
   - Widget tests for Phone and TV layouts.
   - `flutter analyze` clean, `cargo check --lib` clean, and `probe_android_api.py` 22/22 green.

### Out of Scope (Deliberately Excluded)
- Modifying backend Axum route contracts or database schemas (existing endpoints are 100% complete and verified).
- Altering web SPA admin pages (`/manage`, `/devices`).
- Modifying Flutter video player engine or HLS pipeline.

---

## 2. Architecture & File Structure

```text
flutter_client/lib/
├── core/api/api_endpoints.dart                    // Add storage, transcode dashboard, admin PIN, and scan endpoints
├── features/admin/
│   ├── domain/models/
│   │   ├── storage_audit_model.dart               // StorageAuditReport, StoragePoolInfo, RetentionSettings
│   │   ├── transcode_dashboard_model.dart         // TranscodeDashboardSummary, TranscodeJobItem, HardwareGpuInfo
│   │   ├── connected_device_model.dart            // ConnectedDevice, DeviceStats
│   │   ├── library_scan_model.dart                // ScanStatusResponse
│   │   └── audit_log_model.dart                   // AuditLogEntry, AuditLogResponse
│   ├── infrastructure/
│   │   └── admin_repository.dart                  // All Admin REST API calls using shared ApiClient
│   └── presentation/
│       ├── controllers/
│       │   ├── admin_hub_controller.dart          // Section tab selection & state orchestration
│       │   ├── storage_controller.dart            // Storage audit, retention policy, purge orphans
│       │   ├── transcode_dashboard_controller.dart// Dual-GPU telemetry, active jobs, cancel, sweep
│       │   ├── connected_devices_controller.dart  // Device listing, renaming, deletion
│       │   └── library_maintenance_controller.dart// Scan trigger & polling, PIN rotation, audit logs
│       ├── screens/
│       │   ├── admin_hub_screen.dart              // Top-level hub with responsive tab/rail navigation
│       │   ├── storage_management_screen.dart     // Storage pools, retention settings & orphan purge
│       │   ├── transcode_dashboard_screen.dart    // Dual-GPU HUD, active jobs & recent history
│       │   ├── connected_devices_screen.dart      // Registered devices & management actions
│       │   └── library_maintenance_screen.dart    // TMDb scanner, PIN rotation & audit logs
│       └── widgets/
│           ├── admin_hub_tile.dart                // SettingsScreen entry tile (role-gated)
│           ├── storage_pool_hud.dart              // D: and E: drive utilization cards
│           ├── active_transcode_card.dart         // Job card with progress, speed, fps, ETA, cancel
│           ├── device_item_card.dart              // Device card with status chip, rename & delete
│           ├── change_pin_sheet.dart              // Modal sheet for updating Admin PIN
│           └── audit_log_item_tile.dart           // Formatted audit log entry
```

---

## 3. Detailed Implementation Breakdown

### 12.4a — Admin Hub Navigation & Access Gating
1. **`AdminHubTile` in `SettingsScreen`:**
   - Placed directly under `AccountProfileCard` / `TvAccountProfileCard`.
   - Authenticated Admin mode: Prominent card with Obsidian/Gold styling, badge "Admin Access Active", and subtitle "Storage, Transcodes, Devices & Library".
   - Guest / Viewer mode: Shows lock icon with "Admin Tools (Locked) • Tap to enter PIN".
   - Tapping when unauthenticated triggers `AdminPinSheet` (Phone) or `TvAdminPinPad` (TV). When valid PIN is verified, navigates into `AdminHubScreen`.
2. **`AdminHubScreen` Layout:**
   - **Phone Form Factor:** Top AppBar with title "Admin Hub" and horizontal scrolling segment pills (`Storage`, `Transcodes`, `Devices`, `Maintenance`), rendering the selected section in an animated view.
   - **Android TV Form Factor:** 1080p landscape layout with a left sidebar navigation rail (D-pad focusable) and content pane on the right.

### 12.4b — Storage Telemetry & Retention Management
1. **Storage Pool HUD:**
   - Calls `GET /api/system-status` and `GET /api/storage/audit`.
   - Renders Drive `D:` (High-capacity HDD for video library) and Drive `E:` (Fast SSD for runtime, PostgreSQL, and transcode caches).
   - Visual progress bars with color thresholds (Green < 80%, Amber 80–90%, Red > 90%) and free space labels.
2. **Post-Transcode Retention Policy:**
   - Calls `GET /api/storage/settings` and `POST /api/storage/settings`.
   - Allows selecting:
     - `keep`: Retain transcoded HLS chunks permanently.
     - `archive`: Keep for a grace period, then compress/archive.
     - `purge_cache`: Auto-purge completed caches to maximize SSD headroom.
3. **Orphaned Cache Audit & Purge:**
   - Displays orphan preview caches and orphan HLS transcode caches with human-readable byte sizes.
   - "Purge Orphaned Caches" button opens a confirmation dialog warning that unlinked transcode caches will be unlinked.
   - Calls `POST /api/storage/purge-orphans` (`{ "dry_run": false }`) and re-audits storage upon completion.

### 12.4c — Transcode Dashboard & Dual-GPU Telemetry
1. **Hardware Engine HUD:**
   - Calls `GET /api/transcode/dashboard`.
   - Displays AMD Radeon RX 560X (Discrete, adapter 1) and AMD Radeon Vega 8 (Integrated, adapter 0).
   - Shows active encoding vs idle status and overall queue ETA.
2. **Active Transcode Jobs:**
   - Lists running and queued transcode jobs with poster thumbnail, movie title, year, preset/mode, percent progress, speed (e.g. `2.4x`), fps (`58 fps`), and estimated remaining time.
   - Each card provides a "Cancel" button calling `POST /api/transcode/jobs/{filename}/cancel`.
3. **Recent Transcode History & Sweeper:**
   - Lists last 20 completed, canceled, or failed transcode jobs with elapsed time and duration.
   - "Sweep Inactive Jobs" action button calling `POST /api/transcode/sweep` to clean stale database job rows.

### 12.4d — Connected Devices Management
1. **Device Registry & Presence:**
   - Calls `GET /api/devices`.
   - Displays all registered clients with presence indicator:
     - 🟢 Active Now (last seen < 3 minutes)
     - 🟡 Idle (last seen < 30 minutes)
     - ⚪ Offline
   - Displays friendly name, hardware model, operating system, IP address, connection network path (LAN / Cloudflare Tunnel / WAN), and last active timestamp.
2. **Device Management Actions:**
   - Rename Device: Opens a dialog/sheet with text input, calling `POST /api/devices/rename` (`{ "device_id": id, "name": newName }`).
   - Forget / Delete Device: Opens a confirmation dialog, calling `POST /api/devices/delete` (`{ "device_id": id }`).

### 12.4e — Library Maintenance & Security Tools
1. **TMDb Library Scan Trigger:**
   - Displays current scanner status (`GET /api/scan`).
   - "Trigger Full Library Scan" button calls `POST /api/scan`.
   - Animated progress spinner when scanning is active, polling every 2 seconds until status returns to `idle`.
   - Report card showing: Discovered files, Unindexed files, Indexed movies, Pruned orphans, and Subtitles acquired.
2. **Admin PIN Rotation:**
   - "Change Admin PIN" action opens `ChangePinSheet`.
   - Requires Current PIN and New 4-digit PIN (with confirmation).
   - Calls `POST /api/admin/pin` (`{ "current_pin": "...", "new_pin": "..." }`).
   - Updates stored PIN in `AuthNotifier` if "Remember PIN" was enabled.
3. **Security Audit Logs Viewer:**
   - Calls `GET /api/admin/audit-logs?limit=50&offset=0`.
   - Renders a clean chronological event stream showing action icon, event type (`pin_change`, `device_assign`, `device_rename`, `device_delete`, `cache_purge`), actor, IP address, and human-readable timestamp.

---

## 4. Test Strategy & Verification

### Unit & Repository Tests
1. `admin_models_test.dart`: Serialization and deserialization of storage audit, transcode dashboard, devices list, scan status, and audit logs.
2. `admin_repository_test.dart`: Mock Dio tests for all admin endpoints verifying headers (`X-Admin-Pin`, `session_token`), request bodies, and error handling.
3. `admin_controllers_test.dart`: State transitions, polling cancellation, error states, and optimistic UI updates for storage, transcodes, devices, and library maintenance.

### Widget Tests
1. `admin_hub_tile_test.dart`: Gating check in `SettingsScreen` (unauthenticated shows lock prompt; admin shows direct entry).
2. `storage_management_view_test.dart`: Storage pool cards, retention selection, and orphan purge confirmation.
3. `transcode_dashboard_view_test.dart`: Dual-GPU telemetry, active transcode card rendering, cancel button dispatch, and sweep action.
4. `connected_devices_view_test.dart`: Device presence chips, rename modal, and delete action.
5. `library_maintenance_view_test.dart`: Scan button trigger, scanning spinner, PIN rotation sheet, and audit logs listing.

### Regressions & Backend Contracts
1. `flutter analyze`: Assert 0 errors and 0 warnings.
2. `cargo check --lib`: Verify backend unaffected.
3. `python scripts/probe_android_api.py`: Verify 22/22 endpoints pass without contract changes.

---

## 5. Exit Criteria & Checkable Artifacts

- [ ] `AdminHubTile` embedded in `SettingsScreen`, opening the Admin Hub for Admins and prompting for PIN for Guest/Viewer.
- [ ] `AdminHubScreen` operational on Phone (segmented tabs) and Android TV (D-pad sidebar rail).
- [ ] Storage & Retention Management screen fully working (Drive D/E HUD, retention setting, orphan purge).
- [ ] Transcode Dashboard fully working (Dual-GPU telemetry, active jobs with cancel, recent jobs, sweep).
- [ ] Connected Devices Management screen fully working (presence chips, rename, delete).
- [ ] Library Maintenance screen fully working (scan trigger with status polling, PIN change, audit logs).
- [ ] Full Flutter test suite passing (`test/features/admin/`).
- [ ] `flutter analyze` passes with 0 issues.
- [ ] All 22 Android backend endpoints pass contract verification.
- [ ] Walkthrough document `docs/PHASE_12_SLICE_12_4_WALKTHROUGH.md` created.
