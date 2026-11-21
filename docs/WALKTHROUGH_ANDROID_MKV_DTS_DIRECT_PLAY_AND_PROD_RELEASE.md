# Walkthrough: Android MKV DTS/TrueHD Direct Play & Production Deployment

**Date:** 2026-11-21  
**Author:** Antigravity  
**Branch:** `feat/android-mkv-dts-direct-play`  
**Commits:** `82121f0`, `19a6eb0`, `bb2304b`  
**Release Version:** Backend `0.1.0` (Release build), Frontend React 19 SPA (`web/dist/`), Android Client `v1.4.10+156`  
**Service:** `MediaServerRust` (NSSM Windows Service on `:8000`)

---

## 1. Executive Summary

This release resolves two critical operational and playback bottlenecks identified during active 4K UHD transcoding and playback of *The Odyssey (2026)*:

1. **Thermal Safeguard Retry Decoupling**:
   - Transcode jobs paused by the thermal safeguard (e.g. GPU junction or package temperature hitting the safety threshold) are marked with `[THERMAL_PAUSE]`.
   - Thermal pauses decrement the job's `attempts` count on failure (`attempts = GREATEST(0, attempts - 1)`), exempting them completely from the generic 3-attempt circuit breaker in `transcode_sweeper.rs`.
   - In both the React and Flutter admin dashboards, thermal pauses are distinguished by an amber **THERMAL COOLDOWN** badge rather than a generic red failure.

2. **Android MKV DTS/TrueHD Direct Play**:
   - *The Odyssey* (4K UHD BluRay x265 10bit) contains a primary DTS-HD MA audio stream and a secondary EAC3 stream.
   - The backend `/api/media-info` endpoint previously omitted DTS/TrueHD from Android MKV direct-play evaluation and only checked the first audio stream, causing `direct_play = false` and omitting "Original (4K Direct Play - Lossless)" from the Android quality selector.
   - Android's playback engine uses `media_kit` (backed by `libmpv`), which natively decodes MKV, HEVC, DTS, DTS-HD MA, and TrueHD in software with zero transcode overhead.
   - We updated `evaluate_direct_play_streams` in Rust to whitelist DTS, DCA, TrueHD, Vorbis, and PCM for Android MKV, and to evaluate across all audio streams in the container.
   - In the Flutter client (`player_screen.dart`), the quality sheet now ensures direct play is always visible and selectable when supported, properly updating the active playback mode.

3. **Production Deployment & Seamless Resumption**:
   - Built optimized production frontend bundle (`web/dist/`).
   - Built optimized native release binary (`rust/target/release/media-server-api.exe`).
   - Built Android release APK (`flutter_client/build/app/outputs/flutter-apk/app-release.apk`, 97.2 MB) and published to `E:\MediaServer\updates\production\media-server-client.apk` with updated `manifest.json`.
   - Deployed release binary to persistent Windows Service `MediaServerRust`.
   - Active transcode Job 1150 (*The Odyssey*) resumed automatically via checkpoint recovery and is actively transcoding at >62.5% progress.

---

## 2. Key Changes by Component

### 2.1 Backend (`rust/src/routes/media_pipeline/media_info.rs`)
- Added `evaluate_direct_play_streams(container, video_codec, audio_codecs, is_android) -> bool`.
- Expanded the Android MKV audio codec whitelist to:
  `"aac" | "ac3" | "eac3" | "mp3" | "opus" | "flac" | "dts" | "dca" | "truehd" | "vorbis" | "pcm_s16le" | "pcm_s24le"`
- Extracted all audio streams from `probe.streams` (`audio_codecs: Vec<&str>`) and permitted direct play if any stream matches the supported codec set.
- Preserved `evaluate_direct_play` as a backward-compatible wrapper.
- Added comprehensive unit tests:
  - `test_android_mkv_dts_direct_play`: MKV + HEVC + DTS on Android = `true`.
  - `test_android_mkv_truehd_direct_play`: MKV + HEVC + TrueHD on Android = `true`.
  - `test_web_mkv_dts_requires_transcode`: MKV on non-Android web browser = `false`.
  - `test_multi_audio_fallback`: MKV with unsupported primary + supported secondary on Android = `true`.

### 2.2 Flutter Client (`flutter_client/`)
- **`player_screen.dart`**:
  - `_openQualitySheet()`: Compute `supportsDirect = _playbackMode == PlaybackMode.directPlay || hasDirectReady`. This ensures that even when a user is currently streaming an HLS tier, the "Original (4K Direct Play - Lossless)" option remains accessible.
  - `_handleQualitySelected()`: Update `_playbackMode` to `PlaybackMode.directPlay` when direct source is selected, and `PlaybackMode.hls` when an HLS tier is selected.
- **`quality_selector_sheet_test.dart`**:
  - Added unit test `renders Original (4K Direct Play - Lossless) when direct option is 4K`, asserting label and dimensions subtitle `3840×2160 • Bitstream direct play without transcoding`.

### 2.3 Mobile App Distribution (`updates/production/`)
- Deployed release APK to `E:\MediaServer\updates\production\media-server-client.apk`.
- Updated `E:\MediaServer\updates\production\manifest.json` with:
  - Version: `1.4.10` (versionCode `156`)
  - SHA256: `1dab9811256a5204c05e2a3b4ba93576940e9c1a6873ffe253d17bd362078f18`
  - Size: `101,931,072 bytes` (97.2 MB)
  - Git Commit: `bb2304b`

---

## 3. Verification & Test Outcomes

### 3.1 Rust Backend Parity Suite
```powershell
cargo fmt --manifest-path rust/Cargo.toml --check       # PASSED
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings # PASSED (0 warnings)
cargo test --manifest-path rust/Cargo.toml -- routes::media_pipeline::media_info
```
**Outcome:**
```text
running 4 tests
test routes::media_pipeline::media_info::tests::test_web_mkv_dts_requires_transcode ... ok
test routes::media_pipeline::media_info::tests::test_multi_audio_fallback ... ok
test routes::media_pipeline::media_info::tests::test_android_mkv_dts_direct_play ... ok
test routes::media_pipeline::media_info::tests::test_android_mkv_truehd_direct_play ... ok

test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured
```

### 3.2 React Frontend SPA Suite
```powershell
npm --prefix web run typecheck                         # PASSED (0 errors)
npm --prefix web run test                              # PASSED (46 test files, 338 tests passed)
```

### 3.3 Flutter Client Suite
```powershell
flutter analyze                                        # PASSED (No issues found)
flutter test test/features/player/quality_selector_sheet_test.dart # PASSED (5 tests passed)
```

### 3.4 Live Production Verification
1. **Live `/api/media-info` for Android Client**:
   ```powershell
   GET http://127.0.0.1:8000/api/media-info/The%20Odyssey...mkv?client=android
   ```
   **Response:**
   ```json
   {
     "direct_play": true,
     "needs_transcode": false,
     "quality_ladder": [
       {
         "label": "Direct Play (Source)",
         "quality": "source",
         "height": 2160,
         "width": 3840,
         "bitrate": 20126212,
         "is_direct": true,
         "is_ready": true
       }
     ]
   }
   ```
2. **Live `/api/media-info` for Web Client (No Regressions)**:
   ```powershell
   GET http://127.0.0.1:8000/api/media-info/The%20Odyssey...mkv
   ```
   **Response:**
   ```json
   {
     "direct_play": false,
     "needs_transcode": true,
     "quality_ladder": [
       {
         "label": "Direct Play (Source)",
         "quality": "source",
         "height": 2160,
         "width": 3840,
         "bitrate": 20126212,
         "is_direct": true,
         "is_ready": false
       }
     ]
   }
   ```
3. **Live Transcode Resumption**:
   - `MediaServerRust` was cleanly restarted.
   - Job 1150 was claimed by `rust-worker-7136-rx` and resumed encoding at 62.55% progress.
