# Implementation Plan: Android MKV DTS/TrueHD Direct Play & Production Deployment

**Date:** 2026-11-21  
**Author:** Antigravity  
**Target:** Native Rust Backend (`rust/src/routes/media_pipeline/media_info.rs`) + Flutter Client (`flutter_client/`) + Production Release  
**Status:** DRAFT (Awaiting User Review & Sign-Off)

---

## 1. Problem Statement & Motivation

On the Android / Fire TV client, when attempting to play *The Odyssey (2026)* (2160p UHD BluRay x265 10bit), the **Direct Stream (4K Source)** option is completely omitted from the player's quality ladder.

### Root Causes Identified:
1. **DTS / TrueHD Audio Omission**:
   - The primary audio track of *The Odyssey* is `dts` (DTS-HD Master Audio), with a secondary track of `eac3`.
   - In `rust/src/routes/media_pipeline/media_info.rs`, `evaluate_direct_play()` limits Android MKV audio to `"aac" | "ac3" | "eac3" | "mp3" | "opus" | "flac" | ""`.
   - `dts`, `dca`, and `truehd` were omitted.
2. **First-Audio-Stream Blindness**:
   - `media_info.rs` only evaluated the first audio stream (`probe.first_stream("audio")`). Even though stream 2 is a fully supported `eac3` track, the primary track's `dts` caused the server to return `direct_play = false` and `is_ready = false` on `Direct Play (Source)`.
3. **Flutter Quality Sheet Suppression**:
   - In `flutter_client/lib/features/player/presentation/screens/player_screen.dart`, `QualitySelectorSheet.show` is invoked with `supportsDirectPlay: _playbackMode == PlaybackMode.directPlay`.
   - Because the server reported `direct_play = false`, `supportsDirectPlay` evaluated to `false`, causing `quality_selector_sheet.dart` to completely omit "Original (Direct Play)" from the options modal.
   - However, the Flutter client's playback engine is **`media_kit` (backed by `libmpv`)**, which natively decodes MKV, HEVC, DTS, DTS-HD MA, and TrueHD in software with zero transcode overhead.

---

## 2. Solution Architecture & Scope

```text
Client (Android / Fire TV)
  │
  ├─> GET /api/media-info/<filename>?client=android
  │     └─> evaluate_direct_play_streams():
  │           - MKV container
  │           - HEVC / H.264 / AV1 video
  │           - DTS / DTS-HD / TrueHD / EAC3 / AC3 / AAC / FLAC audio
  │           - Evaluates ALL audio streams (permits direct play if any track matches)
  │           └─> Returns: direct_play: true, quality_ladder[0].is_ready: true
  │
  └─> Player Quality Selector Sheet
        └─> Always exposes "Original (4K Direct Play - Lossless)" on Android/Fire TV
        └─> Selecting "source" streams RFC 7233 byte-range from `/media/<encoded>` directly
```

### 2.1 Backend Changes (`rust/src/routes/media_pipeline/media_info.rs`)
- Expand audio codec whitelist for `is_android && container == "mkv"` to include:
  `"aac" | "ac3" | "eac3" | "mp3" | "opus" | "flac" | "dts" | "dca" | "truehd" | "vorbis" | "pcm_s16le" | "pcm_s24le"`
- Support multi-audio stream evaluation:
  Inspect all audio streams in `probe.streams`. If any stream matches the supported codec set, permit `direct_play`.
- Preserve existing `evaluate_direct_play` function signature for full backward compatibility with existing tests.

### 2.2 Flutter Client Changes (`flutter_client/`)
- **`player_screen.dart`**:
  - In `_openQualitySheet()`, set `supportsDirectPlay: true` whenever on Android / Fire TV or whenever the quality ladder includes a direct source entry.
- **`quality_selector_sheet.dart`**:
  - Always render "Original (Direct Play)" (or "Original (4K Direct Play - Lossless)" for 2160p) when direct stream is available.
- **`player_media_resolver.dart`**:
  - Ensure selecting `source` routes directly to `$serverOrigin/media/$encoded` with range requests.

### 2.3 Production Release & Deployment Plan
1. **Compilation**:
   - Build frontend production bundle: `npm --prefix web run build` (`web/dist/`).
   - Build optimized release backend: `cargo build --release --manifest-path rust/Cargo.toml` (`rust/target/release/media-server-api.exe`).
2. **Production Service Update**:
   - Check status of active transcode Job 1150 (currently at ~48.3%+).
   - Once ready, copy `rust/target/release/media-server-api.exe` to `E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe`.
   - Restart persistent Windows Service `MediaServerRust` via PowerShell (`Restart-Service MediaServerRust`).
   - Confirm service status is `Running` and `:8000` responds.
3. **Client Release**:
   - Run `flutter build apk --release` in `flutter_client/` to generate updated Android release APK.

---

## 3. Verification Plan & Test Strategy

1. **Rust Unit Tests**:
   - `test_android_mkv_dts_direct_play`: Assert that an MKV with HEVC video and DTS audio returns `direct_play = true` for Android.
   - `test_android_mkv_truehd_direct_play`: Assert that an MKV with HEVC video and TrueHD audio returns `direct_play = true` for Android.
   - `test_web_mkv_dts_requires_transcode`: Assert that a non-Android web browser client still returns `direct_play = false` (preventing unplayable HTML5 video).
   - `test_multi_audio_fallback`: Assert that an MKV where track 1 is unsupported but track 2 is supported returns `direct_play = true` for Android.
2. **Flutter Parity Tests**:
   - Run `flutter test test/transcode_dashboard_model_test.dart` and player resolver tests.
   - Run `flutter analyze` ensuring 0 issues.
3. **Live Endpoint & Client Validation**:
   - Query `GET /api/media-info/The%20Odyssey...mkv?client=android` on live server and assert `direct_play: true` and `is_ready: true`.
   - Open movie in Android app and verify "Original (4K Direct Play - Lossless)" appears in the quality ladder.

---

## 4. Risks & Mitigations

- **Risk**: A low-end Android device without DTS hardware decoding.  
  **Mitigation**: `media_kit` bundles `libmpv`, which includes software FFmpeg decoders for DTS and TrueHD. It does not rely on Android hardware MediaCodec for audio decoding.
- **Risk**: Interruption of active transcode Job 1150 during service restart.  
  **Mitigation**: Checkpoint resumption (verified in Slices 20 and 21) ensures that any restart immediately resumes from the last completed segment without data loss. We will deploy after user sign-off.
