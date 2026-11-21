# Walkthrough: Player Error Dismissal, Decoder Mode Settings, & 4K Transcoding Fix

**Date:** 2026-11-21  
**Target:** Flutter Android Client (Mobile & Fire TV) + Rust Media Server Backend  
**Release Version:** v1.4.11 (versionCode: 157, Channel: `production`)

---

## 1. Executive Summary

This walkthrough documents the end-to-end resolution of three interconnected issues:
1. **Persistent "Player encountered an error" overlay bug**: Fixed transient false-positive engine errors lingering over actively playing video during direct playback, seeking, and resuming on both phone (iQOO Neo 7 Pro) and Fire TV Stick 4K.
2. **Fire TV Stick 4K (1st Gen) 50% Frame Drop Issue**: Resolved hardware bottleneck caused by `mediacodec-copy` bus congestion by switching the Android default to zero-copy direct Surface decoding (`mediacodec`) and providing a configurable, persistent in-player Decoder Mode selector (`HW Direct`, `HW Copy`, `SW CPU`).
3. **4K Transcoding Pipeline AMF Driver Hang**: Diagnosed and repaired AMD AMF encoder freeze on 4K HEVC chunks by stripping HDR10 / SMPTE 2084 metadata tags from NV12 surfaces (`setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709`), allowing both RX 560X and Vega 8 to hardware-transcode 4K streams smoothly with thermal protection.

---

## 2. Key Deliverables & Changes

### A. Android Client Playback & Decoder Architecture (`flutter_client/`)

1. **Decoder Modes Domain Model (`flutter_client/lib/features/player/domain/player_models.dart`)**:
   - Added `enum DecoderMode { hardwareDirect, hardwareCopy, software, auto }`.
   - Provided display properties (`label`, `badge`, `description`, `toMpvHwdec()`).
   - Mapped `hardwareDirect` -> `'mediacodec'`, `hardwareCopy` -> `'mediacodec-copy'`, `software` -> `'no'`, `auto` -> `'auto'`.

2. **Player Controller Interface (`flutter_client/lib/features/player/domain/player_controller_interface.dart`)**:
   - Added `DecoderMode get decoderMode;`
   - Added `Future<void> setDecoderMode(DecoderMode mode);`

3. **MediaKit Player Adapter (`flutter_client/lib/features/player/data/media_kit_player_adapter.dart`)**:
   - **Default Decoder**: Changed Android default hardware decoder from `mediacodec-copy` to zero-copy direct `mediacodec` (renders straight to Android `SurfaceView` without round-tripping 600 MB/s uncompressed 4K video frames through system RAM).
   - **Persistence**: Saved selected decoder mode in `SharedPreferences` (`player_decoder_mode`), restoring user preference on next playback session.
   - **Watchdog De-escalation Removal**: Removed aggressive keyword watchdog that demoted hardware decoding to CPU software (`hwdec: 'no'`) on non-fatal engine info messages.
   - **Active Error Suppression**: Filtered out transient engine error messages in `player.stream.error` when the video is actively playing or playback position is advancing.

4. **In-Player Decoder Mode Selector (`flutter_client/lib/features/player/presentation/widgets/decoder_selector_sheet.dart`)**:
   - Created mobile touch and Fire TV D-pad accessible modal bottom sheet.
   - Highlights the active mode (`HW-DIRECT`, `HW-COPY`, `SW-CPU`) with technical badges and explanatory descriptions.
   - Fully integrated with `TvFocusable` for spatial navigation on Android TV / Fire TV remotes.

5. **Player Controls & Error UI Polish (`flutter_client/lib/features/player/presentation/` & `player_screen.dart`)**:
   - Added `Decoder` mode pill button (`HW-DIRECT`) adjacent to `Quality` selector in `PlayerControlsOverlay`.
   - Updated D-pad key navigation matrix to support index 5 for Decoder selection.
   - Added position stream listener in `PlayerScreen`: automatically clears error banners (`_errorMessage = null`) and sets state to `playing` as soon as playback position advances past 0:00.
   - Guarded fatal error dialog rendering with `!isActuallyPlaying`, ensuring error dialogs never render over top of playing video.

---

### B. Rust Backend 4K AMF Transcoding Fix (`rust/`)

1. **AMF NV12 Color Space Metadata Reset (`rust/src/services/media_pipeline/gpu_service.rs`)**:
   - When downscaling 10-bit HDR video to 8-bit NV12 via `vpp_amf`, AMD's AMF encoder (`AMFEncoderUVEHEVCImpl`) hung indefinitely because SMPTE 2084 PQ HDR tags remained on an 8-bit SDR surface.
   - Added `,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709` to the filter chain.
   - Both AMD Radeon RX 560X (28 fps) and Vega 8 (16 fps) now encode 4K HEVC cleanly without driver stall or timeout.

---

## 3. Verification & Test Results

1. **Rust Test Suite**:
   - `cargo test --manifest-path rust/Cargo.toml test_get_ffmpeg_video_args_amf_2160p_uses_hevc_and_hvc1_tag` -> **PASSED**.
2. **Flutter Static Analysis**:
   - `flutter analyze` -> **No issues found! (0 warnings, 0 errors)**.
3. **Flutter Full Test Suite (`.\scripts\run_flutter_tests.ps1`)**:
   - **433 tests passed, 0 failures, 13 skipped** (live HTTP integration suite skipped as expected).
   - Added 2 new tests in `player_screen_test.dart`:
     - `does not show fatal error dialog if player is actively playing despite error message` -> **PASSED**.
     - `clears error message when position advances during playback` -> **PASSED**.
4. **Active 4K Transcode Progress**:
   - Job 1148 (*The Odyssey* 2160p): Chunks 0 to 21 completed and running at ~0.86x–1.15x speed, currently over 15% complete with thermal governor actively managing safe GPU temperatures below 90°C.
