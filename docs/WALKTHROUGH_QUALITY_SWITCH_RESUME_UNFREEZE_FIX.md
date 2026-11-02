# Walkthrough: Quality Switch Auto-Resume & Playback Unfreeze Fix

**Release:** Android Client 1.4.3 (Build 149)  
**Date:** 2026-11-02  
**Author:** Antigravity Agent  
**Status:** Verification Passed & Production Published  

---

## 1. Overview of Delivered Changes

This release resolves the playback freeze encountered on Android devices when switching from Direct Play (MKV/HEVC) to a transcoded HLS stream (such as 1080p).

### What Was Fixed
1. **Threaded Play State (`play: wasPlaying`) to Prevent `libmpv` Paused Lockup:**
   - In `PlayerControllerInterface`, added `bool play = true` to the `open()` contract.
   - In `MediaKitPlayerAdapter.open()`, passed `play: play` directly to `player.open(media, play: play)`. This ensures `libmpv` starts in active playback mode immediately without entering a paused state (`pause=yes`) followed by a racing unpause command that got dropped.
   - In `PlayerScreen._handleQualitySelected()`, passed `play: wasPlaying` into `_controller.open(newUrl, startPosition: currentPos, play: wasPlaying)` so that actively playing streams resume seamlessly, while paused streams remain cleanly paused at `currentPos`.
2. **Native `start` Property & Seamless HLS Resume:**
   - `Media(url, start: startPosition)` in `package:media_kit` 1.2.6 is only implemented for Web; on native Android engines it is ignored.
   - In `MediaKitPlayerAdapter.open()`, we now explicitly set mpv's native `start` property before loading the stream:
     ```dart
     if (hasStartPosition) {
       await (nativePlatform as dynamic).setProperty(
         'start',
         '${startPosition.inMilliseconds / 1000.0}',
       );
     } else {
       await (nativePlatform as dynamic).setProperty('start', 'none');
     }
     ```
   - In addition, restored `await player.seek(startPosition)` after `player.open()`. With `#EXT-X-START:TIME-OFFSET=0` removed on the backend, seeking in segmented HLS playlists executes instantaneously without stalls or buffer hangs.
3. **Watchdog Stale-Position Disarm Prevention:**
   - Fixed the watchdog listener in `MediaKitPlayerAdapter` so that `(pos - baselinePos).abs() > 200ms` and `pos > Duration.zero` are evaluated strictly against active playback progression rather than falsely triggering on the stale position of the previous stream.
4. **Demuxer Property Awaiting:**
   - `_configureNativeDemuxer()` now returns `Future<void>` and is properly awaited before initiating playback.

---

## 2. Modified Files & Components

| File | Changes Made |
| :--- | :--- |
| [`flutter_client/lib/features/player/domain/player_controller_interface.dart`](file:///e:/MediaServer/flutter_client/lib/features/player/domain/player_controller_interface.dart) | Added `bool play = true` parameter to `Future<void> open(...)`. |
| [`flutter_client/lib/features/player/data/media_kit_player_adapter.dart`](file:///e:/MediaServer/flutter_client/lib/features/player/data/media_kit_player_adapter.dart) | Forwarded `play` parameter to `player.open(media, play: play)`; configured native `start` property; restored accurate post-open `seek(startPosition)`; guarded watchdog. |
| [`flutter_client/lib/features/player/presentation/screens/player_screen.dart`](file:///e:/MediaServer/flutter_client/lib/features/player/presentation/screens/player_screen.dart) | Passed `play: wasPlaying` into `_controller.open()` on quality preset selection. |
| [`flutter_client/test/support/recording_player_controller.dart`](file:///e:/MediaServer/flutter_client/test/support/recording_player_controller.dart) | Recorded `openedPlay` and added `play` parameter. |
| [`flutter_client/test/features/player/hls_seek_and_resume_test.dart`](file:///e:/MediaServer/flutter_client/test/features/player/hls_seek_and_resume_test.dart) | Added automated regression test verifying `play` parameter and timestamp retention across active and paused quality switches. |
| Test Mock Controllers (6 files) | Synchronized `open(...)` signatures with `bool play = true`. |
| [`updates/version_registry.json`](file:///e:/MediaServer/updates/version_registry.json) | Registered Android Release `1.4.3` (Build 149) on `production` channel. |

---

## 3. Verification & Test Outcomes

### 3.1 Flutter Static Analysis
- Command: `flutter analyze`
- Result: **0 issues found** across the entire Flutter project.

### 3.2 Flutter Player Test Suite
- Command: `flutter test test/features/player/`
- Result: **121/121 tests passed** (including all playback mode, cast, overlay, timeline, and remote control invariants).

### 3.3 HLS Seeking & Quality Preset Resume Regression Tests
- Command: `flutter test test/features/player/hls_seek_and_resume_test.dart`
- Result: **5/5 passed**:
  - `Media initialization retains start position for HLS streams`
  - `PlayerMediaResolver resolves quality URLs for HLS and Direct Play correctly`
  - `demuxer-lavf-o property string matches the exact libavformat segment option`
  - `Quality preset switch retains play state and start position when active`
  - `QualityOption ladder maintains distinct quality labels and tiers`

### 3.4 Rust Integration Test Suite
- Command: `cargo test --manifest-path rust/Cargo.toml --test integration media_pipeline::chunk_transcode_test`
- Result: **8/8 passed** (completed fMP4 playlist omits `#EXT-X-START`, discontinuity maps verified, stride boundaries verified).

### 3.5 Live Update Server Verification
- Query: `GET http://127.0.0.1:8000/api/app/update?channel=production`
- HTTP Status: `200 OK`
- Payload:
  ```json
  {
    "version": "1.4.3",
    "versionCode": 149,
    "channel": "production",
    "apkUrl": "/api/app/download?channel=production",
    "sha256": "90112511db3a989386ae93d6877961f57ae03fb5c148b46a1be98ca6f8aa58dd",
    "releaseNotes": "Fix quality switch resume and unfreeze playback"
  }
  ```

---

## 4. How the User Can Verify

1. Open the **AHMS** app on your phone.
2. In the app Settings / Update section, check for updates: version **1.4.3 (Build 149)** will be offered automatically.
3. Install the update.
4. Open the movie ***Verity***:
   - Start playing in **Direct Play**.
   - Watch until any timestamp (e.g. 05:20).
   - Open the Quality Selector sheet and choose **1080p (FHD)**.
   - **Verification:** Playback now seamlessly resumes from 05:20 in 1080p without freezing or pausing!
   - Seeking forward/backward on 1080p functions smoothly without infinite buffering.
