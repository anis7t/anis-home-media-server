# Implementation Plan: Android Release Build & Distribution for 4K HEVC Fix

**Document:** `docs/PLAN_ANDROID_RELEASE_BUILD_4K_HEVC_FIX.md`  
**Date:** 2026-10-24  
**Author:** Antigravity  
**Target:** Flutter Android Client (`in.anisparvez.media_server_client`)  
**Version:** `1.2.21` (versionCode `141`)

---

## 1. Context & Motivation

In commit `c8aa0ce`, fixes were introduced to resolve 4K HEVC playback on Android mobile devices:
1. **Dual-Codec HLS Transcoder (Backend):** Upgraded 4K tiers to emit hardware HEVC (`hevc_amf`) with FourCC `hvc1`.
2. **Smart 4K Direct Play Routing (Flutter Client):** In `player_media_resolver.dart` and `player_screen.dart`, selecting 2160p (or 4K) on a native 4K title when direct play is supported automatically routes to lossless RFC 7233 byte-range playback (`/media/<filename>`), providing instant playback with zero server GPU transcode overhead.

However, the installed release APK on the user's phone was built on **October 21** (version `1.2.20`, versionCode `140`). Consequently, the client-side fixes have not yet reached the device. When the user selects "2160p" in the app on their phone:
- The old client does not know about smart 4K direct routing.
- It triggers a server-side on-demand 4K HLS transcode (Job #776) and switches to `/hls/.../2160p/playlist.m3u8`.
- On the server, real-time 4K-to-4K HEVC transcoding on mobile AMD GPUs (Radeon RX 560X + Vega 8) runs at ~0.57× speed with intermittent 180s driver timeouts/GPU hangs, causing the stream to stall or buffer indefinitely.

A new verified release build (`1.2.21`, versionCode `141`) must be compiled and published through the repository's single-step release pipeline (`scripts/release_android.py`) so the user can update their phone.

---

## 2. Scope

### In Scope
- **Pre-build verification:** Run `flutter test` across the player and updater suites to ensure zero regressions in Flutter client code.
- **Monotonic Version Allocation:** Allocate `versionCode 141` (exceeding `lastVersionCode 140` in `updates/version_registry.json`) and display version `1.2.21`.
- **Release Build Compilation:** Build the signed release APK using `scripts/release_android.py` (`flutter build apk --release --build-name=1.2.21 --build-number=141`).
- **Identity & Integrity Verification:** Verify APK package ID (`in.anisparvez.media_server_client`), version code (`141`), version name (`1.2.21`), and calculate SHA-256 digest.
- **Distribution Publication:** Atomically publish the APK and manifest to `updates/production/` and record in `updates/version_registry.json`.
- **Update Feed Verification:** Verify that the server's update endpoints serve the new manifest and APK cleanly.

### Deliberately Out of Scope
- Backend Rust modifications (the Rust Axum server already has all dual-codec HLS and transcode fixes running live on `:8000`).
- Database schema changes.
- Web SPA modifications.

---

## 3. Step-by-Step Implementation Steps

1. **Step 1: Test Verification**
   - Run `flutter test` in `flutter_client/` specifically checking:
     - `test/features/player/player_media_resolver_test.dart`
     - `test/features/player/quality_selector_sheet_test.dart`
     - `test/features/updater/update_controller_test.dart`

2. **Step 2: Build & Publish Release**
   - Execute the canonical release script:
     ```bash
     python scripts/release_android.py --channel production --version 1.2.21 --notes "4K HEVC streaming fixes, smart direct routing, and responsive player polish" --flutter "D:/src/flutter/bin/flutter.bat"
     ```
   - This single command:
     - Allocates `versionCode 141` from `updates/version_registry.json`.
     - Invokes `flutter build apk --release --build-name=1.2.21 --build-number=141`.
     - Reads the resulting APK metadata via `aapt2`.
     - Copies the APK to `updates/production/media-server-1.2.21.apk`.
     - Generates and signs `updates/production/manifest.json`.
     - Updates `updates/version_registry.json`.

3. **Step 3: Verification & Validation**
   - Verify that `updates/production/manifest.json` advertises `version: "1.2.21"` and `versionCode: 141`.
   - Verify that `updates/version_registry.json` has `lastVersionCode: 141`.
   - Query the backend endpoint `GET /api/updates/check?channel=production&current_version_code=140` to confirm the update is advertised to installed clients.

4. **Step 4: User Installation & Verification Instructions**
   - Instruct the user how to update:
     - **Option A (In-App):** Open the app on the phone -> Settings -> "Check for Updates" -> tap Update when 1.2.21 appears.
     - **Option B (Direct Download):** Download the APK directly from the server (`/updates/production/media-server-1.2.21.apk`) or via ADB if connected.

---

## 4. Exit Criteria

- [ ] All Flutter unit tests pass (`0 failures`).
- [ ] Release APK is produced at `flutter_client/build/app/outputs/flutter-apk/app-release.apk` with date timestamp of Oct 24, 2026.
- [ ] APK identity verified: `package=in.anisparvez.media_server_client`, `versionCode=141`, `versionName=1.2.21`.
- [ ] `updates/production/manifest.json` and `updates/version_registry.json` published atomically.
- [ ] `GET /api/updates/check?channel=production&current_version_code=140` returns HTTP 200 with `update_available: true` and download URL.

---

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Gradle / Build Timeout** | Build hangs or takes > 5 min | Use explicit `--flutter D:/src/flutter/bin/flutter.bat`, let Gradle use local daemon and cached Maven dependencies. |
| **Monotonic Version Drift** | In-app updater rejects update | `scripts/release_android.py` enforces monotonic checks against `version_registry.json` before building. |
| **Device Architecture Compatibility** | APK fails to run on phone | Flutter's release APK is a universal fat APK containing ARM64 (`arm64-v8a`), ARMv7 (`armeabi-v7a`), and x86_64 native libraries. |

---

## 6. Open Decisions

- **Release Channel:** `production` (the user's installed phone client is currently on production build 140).
- **Mandatory Flag:** Non-mandatory (allows seamless background download or prompt in settings).
