# Implementation Plan: Android Release Build & Distribution v1.3.0 (Phase 12)

**Document:** `docs/PLAN_ANDROID_RELEASE_BUILD_PHASE_12.md`  
**Date:** 2026-10-24  
**Target:** Flutter Android Client (`in.anisparvez.media_server_client`)  
**Version:** `1.3.0` (versionCode `141`)  
**Channel:** `production`  
**Status:** DRAFT — Awaiting User Approval  

---

## 1. Context & Scope

Phase 12 delivered complete authentication parity and administrative controls across Android Mobile Phones and Android TV / Fire TV:
1. **Google OAuth CustomTab Sign-In:** Direct mobile login with `ahms://auth/callback` deep linking.
2. **Android TV QR Sign-In:** High-contrast 240px QR code, 5-character pair code with live SSE/status polling.
3. **Android TV D-Pad Numeric Keypad:** Full on-screen remote-navigable keypad for direct Admin PIN login.
4. **Mobile Remote TV Pairing Sheet:** Enter TV pairing code from phone settings to link TV session.
5. **Native Admin Management Hub:** Role-gated settings tile, Dual-drive Storage Pool HUD with orphan cache purge, Dual-GPU Transcode Dashboard, Connected Devices Registry with presence chips and renaming, and TMDb library scan trigger with live progress.

A signed, verified production APK build (`1.3.0`, versionCode `141`) will be compiled and published through the repository's canonical release pipeline (`scripts/release_android.py`).

### Scope Boundaries
- **In Scope:**
  - Build signed release APK (`1.3.0`, versionCode `141`) via `scripts/release_android.py`.
  - Atomically update `updates/production/manifest.json` and `updates/version_registry.json`.
  - Copy output binary to `updates/production/media-server-1.3.0.apk`.
  - Verify update manifest via `GET /api/app/update?channel=production` and download via `GET /api/app/download?channel=production`.
  - Create session handoff in `Handoffs/2026-10-24_23-15_antigravity.md`.
  - Update `docs/PROJECT_STATUS.md` with release digest.
  - Commit all release artifacts on `feat/phase-12-flutter-auth-admin-tv-parity`.
- **Deliberately Out of Scope:**
  - Rust backend modifications (Rust Axum server is already verified and clean).
  - React web SPA modifications.

---

## 2. Implementation Steps

### Step 1: Pre-Build Test Sanity Check
- Verify `flutter test test/features/updater/update_controller_test.dart` passes cleanly.

### Step 2: Canonical Release Compilation & Publication
- Execute `scripts/release_android.py`:
  ```bash
  python scripts/release_android.py --channel production --version 1.3.0 --notes "Phase 12: Google OAuth, Android TV QR login, remote TV pairing, and native Admin Management Hub" --flutter "D:/src/flutter/bin/flutter.bat"
  ```
- The script automatically:
  1. Verifies `versionCode 141` exceeds `lastVersionCode 140` in `updates/version_registry.json`.
  2. Compiles `flutter build apk --release --build-name=1.3.0 --build-number=141`.
  3. Verifies APK identity (`packageId`, `versionCode`, `versionName`) via `aapt2`.
  4. Computes SHA-256 checksum.
  5. Atomically publishes the APK, updates `updates/production/manifest.json`, and records `versionCode 141` in `updates/version_registry.json`.

### Step 3: Distribution & In-App Update Verification
- Probe `GET /api/app/update?channel=production`:
  - Assert `version == "1.3.0"` and `versionCode == 141`.
- Probe `HEAD /api/app/download?channel=production`:
  - Assert HTTP 200 with matching `Content-Length`.

### Step 4: Documentation & Session Handoff
- Author `Handoffs/2026-10-24_23-15_antigravity.md` detailing Phase 12 completion, release APK metadata, and next steps.
- Update `docs/PROJECT_STATUS.md` with release version 1.3.0 and SHA-256 digest.

### Step 5: Git Commit
- Stage and commit all release and documentation artifacts on `feat/phase-12-flutter-auth-admin-tv-parity`.

---

## 3. Exit Criteria

1. **APK Compiled:** `updates/production/media-server-1.3.0.apk` created and verified via `aapt2`.
2. **Registry Updated:** `updates/version_registry.json` records `lastVersionCode: 141` and version `1.3.0`.
3. **Feed Live:** `GET /api/app/update?channel=production` returns 1.3.0 (141).
4. **Handoff Created:** `Handoffs/2026-10-24_23-15_antigravity.md` written in IST format.
5. **Clean Working Tree:** All changes committed on `feat/phase-12-flutter-auth-admin-tv-parity`.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| Build memory pressure or timeout | Build fails | Run as managed task with ample wait time and log tracking |
| Manifest/APK hash mismatch | App update fails verification | `scripts/release_android.py` guarantees atomic hash matching via `aapt2` and `hashlib` before writing manifest |
