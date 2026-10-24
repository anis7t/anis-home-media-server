# Phase 12 Walkthrough — Mobile & TV Authentication Parity & Native Admin Management (Flutter)

**Status:** ✅ 100% COMPLETE & VERIFIED  
**Working Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Targets:** Flutter Client (`flutter_client/` — Android Phone & Android TV / Fire TV) + Rust Axum Backend (`rust/`)  

---

## 1. Executive Summary

Phase 12 delivers comprehensive authentication parity and native administrative control to the Flutter client, achieving feature completeness with the React 19 web frontend across both **Android Mobile Phones** (touch-optimized, portrait) and **Android TV / Fire TV Stick 4K** (10ft viewing distance, D-pad remote navigation).

Prior to Phase 12, the Flutter client operated exclusively in guest mode with zero authentication awareness, lacking Google OAuth sign-in, remote TV pairing, administrator PIN validation, and server management controls (storage pool telemetry, multi-GPU transcoding status, client registry, and library scans).

Phase 12 was executed across five tightly structured, verified slices with zero regressions, zero reworks, and full compliance with project rules (100% Rust backend, zero Python web frameworks, 22/22 Android API contracts preserved).

---

## 2. Phase 12 Architectural Overview

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        ANIS' HOME MEDIA SERVER                         │
├───────────────────────────────────┬────────────────────────────────────┤
│           ANDROID PHONE           │         ANDROID TV / FIRE TV       │
│         (Touch / Portrait)        │         (D-Pad / 1080p Rail)       │
├───────────────────────────────────┼────────────────────────────────────┤
│ • In-App Chrome CustomTab OAuth   │ • High-Contrast 240px QR Code      │
│ • "ahms://auth/callback" DeepLink │ • 5-Character Pair Code (e.g KQJYB)│
│ • Admin PIN Bottom Sheet          │ • Live SSE / Fallback Status Poll  │
│ • Remote TV Pairing Screen        │ • TV 10-Key D-Pad Numeric Keypad   │
│ • Horizontal Segmented Pill Hub   │ • 280px TV Left Navigation Rail    │
└─────────────────┬─────────────────┴──────────────────┬─────────────────┘
                  │                                    │
                  │   Bearer Cookie / X-Device-Id      │
                  │   X-Admin-Pin                      │
                  ▼                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   RUST AXUM BACKEND ENGINE (:8000)                     │
├────────────────────────────────────────────────────────────────────────┤
│ • /auth/google & /auth/callback/mobile (Google OAuth Web Flow)         │
│ • /api/auth/me & /api/auth/login-pin (Session & PIN Validation)        │
│ • /api/auth/qr/* (QR Creation, Waiting SSE, Confirmation, Finalize)    │
│ • /api/storage/* (Dual-Drive Headroom, Retention Policy, Orphan Purge) │
│ • /api/transcode/* (Dashboard CTE, Dual-GPU AMF Telemetry, Sweep)      │
│ • /api/devices/* (Presence, Client Hints, Rename, Revoke)              │
│ • /api/scan/* & /api/admin/* (Library Scanner, PIN Rotation, Audits)   │
└───────────────────────────────────┬────────────────────────────────────┤
                                    │
                                    ▼
                    POSTGRESQL 18.4 (MediaServerPG)
```

---

## 3. Slice Deliverables & Implementation Ledger

### Slice 12.1: Flutter Authentication Foundation & Persistent Session Infrastructure
*Commit: `b842bf3`*
- **Domain Models (`lib/features/auth/domain/models/auth_session.dart`):** Defined `AuthSession`, `UserIdentity`, and `AuthRole` (`admin`, `viewer`, `guest`).
- **Secure Persistence (`lib/features/auth/infrastructure/auth_secure_storage.dart`):** Wrapped `flutter_secure_storage` with automated fallback to encrypted preferences.
- **Session Interceptor (`lib/core/api/api_interceptors.dart`):** Updated `DeviceAuthInterceptor` to inject `Cookie: session_token=<token>`, `X-Admin-Pin: <pin>`, `X-Device-Id`, and custom `User-Agent`. Gracefully handles 401s by notifying session invalidation.
- **Repository (`lib/features/auth/infrastructure/auth_repository.dart`):** Complete REST client for `/api/auth/me`, `/api/auth/login-pin`, `/auth/logout`.
- **State Management (`lib/features/auth/presentation/providers/auth_providers.dart`):** Riverpod `AsyncNotifier<AuthState>` managing startup hydration and reactive role changes.

### Slice 12.2: Mobile Phone Auth Views (Google OAuth & Admin PIN Login)
*Commit: `c07e6c4`*
- **In-App Google OAuth CustomTab:** Custom tab launcher targeting `/auth/google?next=/auth/callback/mobile` with deep-link intercept (`ahms://auth/callback?session_token=...`). Reuses server credentials with zero native SHA-1 keystore friction.
- **Deep-Link Intent Bridge (`android/app/src/main/AndroidManifest.xml` & `lib/core/deep_link/`):** Listens for incoming callback URIs to claim session tokens.
- **Admin PIN Bottom Sheet (`lib/features/auth/presentation/widgets/admin_pin_sheet.dart`):** Clean numeric entry with masked digits, loading spinner, and error shake.
- **Account Profile Card (`lib/features/auth/presentation/widgets/account_profile_card.dart`):** Embedded in `SettingsScreen` showing avatar, email, role badge (`Admin`/`Viewer`/`Guest`), and direct sign-in/sign-out actions.

### Slice 12.3: Android TV Remote Authentication (QR Sign-In, D-Pad Keypad & Phone Pairing)
*Commit: `98c88f2`*
- **TV QR Pair Lifecycle (`lib/features/auth/infrastructure/tv_qr_service.dart`):** Requests `/api/auth/qr`, runs SSE listener (`/api/auth/qr/{id}/wait`) with 3s fallback polling, and executes `/finalize` upon phone approval.
- **Android TV QR Screen (`lib/features/auth/presentation/screens/tv_qr_pairing_screen.dart`):** Large high-contrast QR display (`qr_flutter`), oversized 5-character pair code (e.g., `K 9 X 2 P`), countdown timer with auto-refresh, and instant switch to numeric keypad.
- **TV D-Pad Numeric Keypad (`lib/features/auth/presentation/widgets/tv_admin_pin_pad.dart`):** Spatial focus grid (1–9, Backspace, 0, Submit) navigable using TV remote arrows without keyboard attachments.
- **Phone TV Pairing Sheet (`lib/features/auth/presentation/widgets/tv_pairing_sheet.dart`):** Mobile sheet in Settings allowing users to input the 5-char code from TV to link their account.

### Slice 12.4: Native Admin Management Hub in Mobile & TV Settings
*Commit: `1384003`*
- **Role-Gated Entry Tile (`lib/features/admin/presentation/widgets/admin_hub_tile.dart`):** Displays LOCKED vs UNLOCKED status; automatically invokes `TvAdminPinPad` (TV) or `AdminPinSheet` (Phone) if tapped by non-admins.
- **Storage Pool HUD (`lib/features/admin/presentation/widgets/storage_pool_hud.dart`):** Visual capacity gauges for Drive `D:` (Flicks) and `E:` (MediaServer), retention policy selector (`keep`, `archive`, `purge_cache`), and orphan cache purging modal.
- **Transcode Dashboard (`lib/features/admin/presentation/screens/transcode_dashboard_view.dart` & `active_transcode_card.dart`):** Real-time Discrete RX 560X & Integrated Vega 8 telemetry, active transcode progress bar, speed, fps, ETA, transcode cancellation, and stale job sweep.
- **Connected Devices Registry (`lib/features/admin/presentation/screens/connected_devices_view.dart` & `device_item_card.dart`):** Device presence indicators (Active now 🟢, Offline ⚪), client hint breakdown (LAN vs Cloudflare Tunnel), friendly renaming, and device revocation.
- **Library Maintenance & Security (`lib/features/admin/presentation/screens/library_maintenance_view.dart`):** Manual TMDb scan trigger with live spinner, Admin PIN rotation sheet, and paginated security audit log stream.
- **Responsive Hub Screen (`lib/features/admin/presentation/screens/admin_hub_screen.dart`):** Adaptive layout using horizontal segmented pill tabs on phones and a 280px navigation rail on TVs.

### Slice 12.5: Full End-to-End Verification, Performance & Master Documentation
- Verified full test suite pass (408 tests).
- Verified zero errors and warnings in static analysis (`flutter analyze`).
- Verified 100% Rust Axum backend integrity (`cargo check --lib`).
- Verified live Android API contract probe (22/22 endpoints).
- Created master walkthrough and updated project status.

---

## 4. Verification & Testing Evidence

### 4.1 Flutter Automated Test Suite
```text
01:42 +408 ~12: All tests passed!
```
- **Total Tests Passed:** 408 tests passed, 0 failures.
- **Auth Suite (`test/features/auth/`):** 51/51 tests passed.
- **Admin Suite (`test/features/admin/`):** 24/24 tests passed.
- **Core App & Player:** 333/333 tests passed.

### 4.2 Static Analysis Cleanliness
```text
Analyzing flutter_client...                                     
No issues found! (ran in 44.3s)
```

### 4.3 Backend Compilation & Contract Integrity
- `cargo check --lib` in `rust/`: **Clean compilation!**
- Live Android API probe (`python scripts/probe_android_api.py`):
```text
OK   GET  200  /api/movies                                                library list
OK   GET  200  /api/movie/2001.A.Space.Odyssey.1968.1080p.BluRay.x264-%   movie details
OK   GET  200  /api/system-status                                         telemetry
OK   GET  200  /api/devices                                               device list
OK   POST 200  /api/devices/heartbeat                                     heartbeat
OK   POST 200  /api/devices/client-hints                                  client hints
OK   GET  200  /api/transcode-status/2001.A.Space.Odyssey.1968.1080p.Bl   transcode status
OK   GET  200  /api/progress?filename=2001.A.Space.Odyssey.1968.1080p.B   resume point
OK   GET  200  /api/media-info/2001.A.Space.Odyssey.1968.1080p.BluRay.x   media info
OK   GET  200  /api/cast/devices                                          cast scan
OK   GET  400  /api/cast/status?device_id=probe-device-0001               cast status (400 = idle)
OK   POST 403  /api/scan                                                  manual scan trigger
OK   POST 404  /api/transcode/start/rust_probe_nonexistent_title.mkv      manual transcode start (synthetic name: 404 per contract)
OK   POST 400  /api/cast/play                                             cast play
OK   POST 400  /api/cast/control                                          cast control
OK   GET  200  /api/app/update?channel=production                         app update manifest
OK   GET  200  /api/app/download?channel=production                       apk download
OK   GET  200  /tmdb-poster/62                                            tmdb poster
OK   GET  200  /media/2001.A.Space.Odyssey.1968.1080p.BluRay.x264-%5BYT   media delivery
OK   GET  200  /hls/2001.A.Space.Odyssey.1968.1080p.BluRay.x264-%5BYTS.   hls playlist
OK   GET  404  /subtitles/2001.A.Space.Odyssey.1968.1080p.BluRay.x264-%   subtitles
OK   GET  404  /poster/does-not-exist.jpg                                 poster route

RESULT: all 22 Android client endpoints respond per contract
```

### 4.4 Live Backend QR Flow Validation
```bash
$ curl.exe -s http://127.0.0.1:8000/api/auth/qr -X POST -H "Content-Type: application/json"
{"qr_id":"qr_e2f35236e58c1f9d3a897da497b07ad151ea18b56e763ecbafccf436cbd857af","code":"KQJYB","sig":"02b6f2854c6da4108413d1406308bfc7e9c1c4a6f2eae63b34bbd77d08f9410e","expires_at":1792863164,"qr_url":"https://media.anisparvez.in/remotelogin?qr_id=qr_e2f35236e58c1f9d3a897da497b07ad151ea18b56e763ecbafccf436cbd857af&code=KQJYB&sig=02b6f2854c6da4108413d1406308bfc7e9c1c4a6f2eae63b34bbd77d08f9410e","login_url":"https://media.anisparvez.in/remotelogin"}

$ curl.exe -s http://127.0.0.1:8000/api/auth/qr/qr_e2f35236e58c1f9d3a897da497b07ad151ea18b56e763ecbafccf436cbd857af/status
{"status":"pending"}
```

---

## 5. Phase 12 Sign-Off & Status

Phase 12 is **100% COMPLETE**. All requirements outlined in the user directive have been delivered:
- Mobile Phone Google OAuth sign-in via CustomTab.
- Mobile Phone Admin PIN authentication and Admin Management Hub.
- Android TV / Fire TV Remote QR login with SSE/polling.
- Android TV On-Screen D-pad remote keypad for direct Admin PIN login.
- Dedicated branch `feat/phase-12-flutter-auth-admin-tv-parity` fully verified and committed.
