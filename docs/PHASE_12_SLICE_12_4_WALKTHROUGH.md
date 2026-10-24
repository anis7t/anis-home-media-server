# Phase 12 Slice 12.4 Walkthrough — Native Admin Management Hub in Mobile & TV Settings

**Status:** ✅ COMPLETED & FULLY VERIFIED  
**Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Targets:** Flutter Client (`flutter_client/` — Android Phone & Android TV / Fire TV) + Rust Axum Backend (`rust/`)  

---

## 1. Executive Summary

Slice 12.4 delivers the **Native Admin Management Hub** for the Flutter client on both Android Mobile phones and Android TV / Fire TV devices. It bridges the administrative and server management capabilities previously available only in the React 19 web SPA (`/manage`) into a native, high-performance, role-gated mobile and TV interface.

The Admin Hub integrates:
1. **Storage Pool Telemetry & Retention Management:** Real-time dual-drive (`D:` Flicks and `E:` MediaServer) headroom, active retention policy selection (`keep`, `archive`, `purge_cache`), and orphan cache reconciliation and purging.
2. **Transcode Dashboard & Dual-GPU Telemetry:** Real-time Discrete AMD Radeon RX 560X (`dx11:1`) and Integrated AMD Vega 8 (`dx11:0`) telemetry, live chunked transcode monitoring with progress bars, ETA, fps/speed, job cancellation, and stale transcode sweeping.
3. **Connected Device Registry & Management:** Real-time device presence (Active now 🟢, Offline ⚪), client hints breakdown (LAN vs Cloudflare Tunnel), friendly renaming dialogs, and device revocation.
4. **Library Maintenance & Security Tools:** Manual TMDb library scanner trigger with live polling state banner, secure Administrator PIN rotation modal, and paginated security audit log stream.

---

## 2. Key Architecture & Deliverables

### A. Core Endpoints & Models
- **`lib/core/api/api_endpoints.dart`**:
  - Registered `/api/storage/audit`, `/api/storage/purge-orphans`, `/api/storage/settings`, `/api/transcode/dashboard`, `/api/transcode/jobs/{filename}/cancel`, `/api/transcode/sweep`, `/api/devices/{id}/rename`, `/api/devices/{id}`, `/api/admin/pin`, `/api/admin/audit-logs`.
- **Domain Models (`lib/features/admin/domain/models/`)**:
  - `storage_audit_model.dart`: Models `StorageDriveInfo`, `ServerStorageInfo`, `CacheAuditData`, `StorageAuditReport`, `StorageRetentionSettings`, and `PurgeResult`.
  - `transcode_dashboard_model.dart`: Models `GpuEngineStatus`, `DualGpuHardwareInfo`, `TranscodeDashboardSummary`, `TranscodeActiveJob`, `TranscodeRecentJob`, and `TranscodeDashboardResponse`.
  - `connected_device_model.dart`: Models `ConnectedDevice`, `DeviceRegistryStats`, and `DeviceListResponse`.
  - `library_scan_model.dart`: Models `LibraryScanStatus`.
  - `audit_log_model.dart`: Models `AuditLogEntry` and `AuditLogResponse`.

### B. Repository & State Management
- **`lib/features/admin/infrastructure/admin_repository.dart`**:
  - Complete REST repository communicating with Axum backend routes. Automatically authenticated via `DeviceAuthInterceptor` (attaching `Cookie: session_token` and `X-Admin-Pin`).
- **Controllers (`lib/features/admin/presentation/controllers/`)**:
  - `storage_controller.dart`: Loads audit report and retention settings, executes orphan purge, updates retention.
  - `transcode_dashboard_controller.dart`: Auto-polls transcode dashboard, cancels jobs, sweeps stale transcodes.
  - `connected_devices_controller.dart`: Fetches client registry, renames devices, deletes/revokes devices.
  - `library_maintenance_controller.dart`: Triggers library scans with periodic polling, rotates Admin PIN, loads audit logs.
- **Master Providers (`lib/features/admin/presentation/providers/admin_providers.dart`)**:
  - Unified Riverpod provider bundle exposing repository, tab selection notifier, and all domain controllers.

### C. Presentation & Responsive Layouts
- **`lib/features/admin/presentation/screens/admin_hub_screen.dart`**:
  - **Phone Form Factor**: Frosted glass top app bar, horizontal swipeable segmented pill chips (`Storage & Retention`, `Transcodes & Dual-GPU`, `Connected Devices`, `Library & Security`), and scrollable tab view.
  - **TV Form Factor**: 1080p landscape layout with left navigation rail (280px), D-pad focusable navigation items with glowing selection states, and expansive right-side management viewport.
- **Embedded Entry Point (`lib/features/settings/presentation/screens/settings_screen.dart` & `admin_hub_tile.dart`)**:
  - "Admin & Server Management" tile in Settings.
  - Role-gated: If user is authenticated as Admin, opens directly. If unauthenticated/Guest/Viewer, invokes `TvAdminPinPad` dialog on TV or `AdminPinSheet` modal on Phone to verify PIN before unlocking.
- **Specialized Widgets (`lib/features/admin/presentation/widgets/`)**:
  - `storage_pool_hud.dart`: Dual-drive progress bars, retention radio options, orphan cache purge modal with dry-run/force options.
  - `active_transcode_card.dart`: Real-time transcode progress, chunk speed, fps, ETA, and cancellation button.
  - `device_item_card.dart`: Presence chip, friendly rename dialog, and device revocation confirmation.
  - `change_pin_sheet.dart`: 4–6 digit PIN entry with confirmation check and secure API rotation.
  - `audit_log_item_tile.dart`: Visual log stream with actor badges and formatted timestamps.

---

## 3. Test & Verification Results

### A. Admin Test Suite (`test/features/admin/`)
- All **24/24** unit and widget tests pass cleanly:
  - `admin_models_test.dart` (7 tests): JSON serialization and fallback parsing for all models.
  - `admin_repository_test.dart` (8 tests): All 10 repository API interactions verified with mock client.
  - `admin_controllers_test.dart` (5 tests): State mutations, error handling, and tab switching.
  - `admin_hub_tile_test.dart` (2 tests): LOCKED vs UNLOCKED badge rendering, PIN prompt gating.
  - `admin_hub_screen_test.dart` (2 tests): Mobile tab switching and TV navigation rail rendering.

### B. Auth Suite Non-Regression (`test/features/auth/`)
- All **51/51** auth tests continue passing with zero regressions across Slices 12.1–12.3.

### C. Static Analysis & Backend Integrity
- `flutter analyze` in `flutter_client/`: **No issues found!** (0 errors, 0 warnings).
- `cargo check --lib` in `rust/`: **Clean compilation!**
- `python scripts/probe_android_api.py`: **22/22 endpoints pass per contract.**

---

## 4. Next Step: Slice 12.5
- Prepare for **Slice 12.5: Full End-to-End Verification, Performance & Documentation** (final Phase 12 sign-off).
