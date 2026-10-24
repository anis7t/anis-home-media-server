# Walkthrough — Phase 12 Slice 12.2: Mobile Phone Auth Views: Google OAuth CustomTab & Admin PIN Login

**Phase:** Phase 12 (Mobile & TV Auth Parity & Native Admin Management)  
**Slice:** 12.2 (Mobile Phone Auth Views: Google OAuth CustomTab & Admin PIN Login)  
**Working Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Status:** ✅ COMPLETE & VERIFIED  

---

## 1. Overview & Delivered Capabilities

Slice 12.2 delivers the user-facing mobile authentication workflows on Android phone, bridging the backend Rust Axum OAuth infrastructure with native Android Custom Tabs and deep linking, alongside an in-app Admin PIN authentication modal sheet.

Delivered capabilities:
1. **Backend Mobile OAuth Deep-Link Bridge (`/auth/callback/mobile`):**
   - Implemented `mobile_oauth_callback_handler` in [rust/src/routes/auth.rs](file:///E:/MediaServer/rust/src/routes/auth.rs).
   - Serves a lightweight, dark obsidian HTML bridge page with automatic JavaScript deep link redirection (`ahms://auth/callback?session_token=<token>`) and a manual fallback button ("Return to Media Server App").
   - Registered `/auth/callback/mobile` route in Axum server router ([rust/src/lib.rs](file:///E:/MediaServer/rust/src/lib.rs)).
2. **Android Custom Tabs & Deep Link Handover:**
   - Added `url_launcher` and `app_links` dependencies to [flutter_client/pubspec.yaml](file:///E:/MediaServer/flutter_client/pubspec.yaml).
   - Configured custom scheme `<intent-filter>` for `ahms://auth/callback` in [flutter_client/android/app/src/main/AndroidManifest.xml](file:///E:/MediaServer/flutter_client/android/app/src/main/AndroidManifest.xml).
   - Created [flutter_client/lib/features/auth/infrastructure/oauth_launcher_service.dart](file:///E:/MediaServer/flutter_client/lib/features/auth/infrastructure/oauth_launcher_service.dart), listening to deep-link streams, extracting `session_token`, and updating `AuthNotifier` via `setSessionToken()`.
   - Wired deep link listener into [flutter_client/lib/features/shell/presentation/screens/app_shell.dart](file:///E:/MediaServer/flutter_client/lib/features/shell/presentation/screens/app_shell.dart).
3. **Modal Admin PIN Bottom Sheet (`AdminPinSheet`):**
   - Created [flutter_client/lib/features/auth/presentation/widgets/admin_pin_sheet.dart](file:///E:/MediaServer/flutter_client/lib/features/auth/presentation/widgets/admin_pin_sheet.dart) with frosted obsidian design, masked numeric input, visibility toggle, inline error messages, and "Remember PIN" persistence toggle.
4. **Account Profile & Auth Card (`AccountProfileCard`):**
   - Created [flutter_client/lib/features/auth/presentation/widgets/account_profile_card.dart](file:///E:/MediaServer/flutter_client/lib/features/auth/presentation/widgets/account_profile_card.dart) with responsive states:
     - **Guest State:** Displays Guest avatar, "Sign In with Google" (offline styled icon with zero network request overhead), and "Admin PIN Login" buttons.
     - **Authenticated State:** Displays user letter/photo avatar, display name, email, role badge (`ADMIN` or `VIEWER`), and "Sign Out" button.
5. **Settings Screen Integration:**
   - Embedded `AccountProfileCard` as the topmost section in [flutter_client/lib/features/settings/presentation/screens/settings_screen.dart](file:///E:/MediaServer/flutter_client/lib/features/settings/presentation/screens/settings_screen.dart), providing immediate visibility and access.

---

## 2. Key Code Changes

| File | Change Description |
|:---|:---|
| [rust/src/routes/auth.rs](file:///E:/MediaServer/rust/src/routes/auth.rs) | Added `mobile_oauth_callback_handler` serving `ahms://auth/callback` deep link HTML bridge. |
| [rust/src/lib.rs](file:///E:/MediaServer/rust/src/lib.rs) | Registered `/auth/callback/mobile` in Axum router. |
| [flutter_client/pubspec.yaml](file:///E:/MediaServer/flutter_client/pubspec.yaml) | Added `url_launcher: ^6.3.0` and `app_links: ^6.3.2`. |
| [flutter_client/android/app/src/main/AndroidManifest.xml](file:///E:/MediaServer/flutter_client/android/app/src/main/AndroidManifest.xml) | Added intent filter for `ahms://auth/callback`. |
| [flutter_client/lib/features/auth/infrastructure/oauth_launcher_service.dart](file:///E:/MediaServer/flutter_client/lib/features/auth/infrastructure/oauth_launcher_service.dart) | Created service for Chrome Custom Tabs launch and deep-link stream token handling. |
| [flutter_client/lib/features/auth/presentation/widgets/admin_pin_sheet.dart](file:///E:/MediaServer/flutter_client/lib/features/auth/presentation/widgets/admin_pin_sheet.dart) | Created modal bottom sheet for Admin PIN entry with error feedback and remember option. |
| [flutter_client/lib/features/auth/presentation/widgets/account_profile_card.dart](file:///E:/MediaServer/flutter_client/lib/features/auth/presentation/widgets/account_profile_card.dart) | Created profile card supporting Guest and Authenticated modes with zero-network Google badge. |
| [flutter_client/lib/features/settings/presentation/screens/settings_screen.dart](file:///E:/MediaServer/flutter_client/lib/features/settings/presentation/screens/settings_screen.dart) | Integrated `AccountProfileCard` into SettingsScreen. |
| [flutter_client/lib/features/shell/presentation/screens/app_shell.dart](file:///E:/MediaServer/flutter_client/lib/features/shell/presentation/screens/app_shell.dart) | Initialized `OAuthLauncherService` deep-link listening on app mount. |
| [flutter_client/test/features/auth/admin_pin_sheet_test.dart](file:///E:/MediaServer/flutter_client/test/features/auth/admin_pin_sheet_test.dart) | Added widget tests for PIN input, validation, successful auth, and error states. |
| [flutter_client/test/features/auth/account_profile_card_test.dart](file:///E:/MediaServer/flutter_client/test/features/auth/account_profile_card_test.dart) | Added widget tests for Guest and Authenticated profile display and action triggers. |

---

## 3. Verification & Test Evidence

### 3.1 Static Analysis Cleanliness
```bash
$ flutter analyze
Analyzing flutter_client...
No issues found! (ran in 30.5s)
```

### 3.2 Flutter Auth & Regression Test Suites
```bash
$ flutter test test/features/auth/
00:04 +31: All tests passed!

$ flutter test test/features/shell/app_shell_test.dart
00:05 +6: All tests passed!
```

### 3.3 Backend Rust Compilation
```bash
$ cargo check --lib
Finished `dev` profile [unoptimized + debuginfo] target(s) in 1.47s
```

### 3.4 Android Client Contract Probe
```bash
$ python scripts/probe_android_api.py
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

---

## 4. Next Step
Proceed to **Phase 12 Slice 12.3: Android TV Remote Authentication (QR Sign-In & On-Screen PIN Pad)**, following Rule 0.1 and Rule 0.3 planning and approval requirements.
