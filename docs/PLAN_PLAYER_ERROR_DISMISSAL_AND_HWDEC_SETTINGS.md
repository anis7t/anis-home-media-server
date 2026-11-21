# Implementation Plan: Player Error Dismissal & Configurable Hardware Decoding

**Date:** 2026-11-21  
**Author:** Antigravity  
**Branch:** `feat/player-error-dismissal-and-hwdec-settings`  
**Target:** Flutter Client (`flutter_client/`)  
**Status:** DRAFT (Awaiting User Review & Sign-Off)

---

## 1. Problem Statement & Motivation

During direct playback of high-bitrate media (such as *The Odyssey (2026)* 4K UHD BluRay x265 10bit) on mobile (iQOO Neo 7 Pro) and TV (Fire TV Stick 4K 1st Gen), two severe UX and playback degradation issues occur:

### Issue 1: Persistent Error Popup Over Active Playback
1. **Initial Playback**: When playback begins, an error card ("Playback Encountered an Error") flashes briefly and disappears once the first video frame arrives.
2. **Seek & Resume Bug**: If the user seeks forward or resumes playback, the error card reappears and **stays permanently on screen**, blocking the controls and picture, even though the movie **continues playing smoothly in the background**.
3. **Root Cause**:
   - `player.stream.error` in `media_kit` fires on transient warnings, demuxer notifications, audio clock resyncs, or seek discontinuities.
   - `media_kit_player_adapter.dart` unconditionally transitions to `PlayerPlaybackState.error` when any error event arrives.
   - `player_screen.dart` sets `_errorMessage = 'Failed to load media or decode stream.'`.
   - `_errorMessage` is only cleared on a discrete transition to `PlayerPlaybackState.playing`. If playback was already running, `player.stream.playing` does not toggle again.
   - `hasError` is evaluated as `_state == PlayerPlaybackState.error || _errorMessage != null`, locking the error card on screen while video and audio are actively playing.

### Issue 2: Severe Frame Drops (~50%) on Fire TV Stick 4K 1st Gen
1. **Phone vs Firestick Discrepancy**:
   - **iQOO Neo 7 Pro**: Qualcomm Snapdragon 8+ Gen 1 (Cortex-X2 @ 3.2 GHz + 3× Cortex-A710 @ 2.8 GHz). Can power through heavy workloads even on CPU fallback.
   - **Fire TV Stick 4K (1st Gen, MT8695)**: Quad-core ARM Cortex-A53 @ 1.7 GHz with 1.5 GB shared RAM.
2. **Root Cause**:
   - The default configuration in `media_kit_player_adapter.dart` uses `hwdec: 'mediacodec-copy'`.
   - In `mediacodec-copy`, every 4K frame (3840×2160 × 10-bit YUV = ~25 MB per frame) is decoded by hardware and then copied across the memory bus into CPU RAM before uploading to OpenGL. At 24 fps, this creates a **~600 MB/s continuous memory bus bottleneck** on a 1.5 GB device, overwhelming the Cortex-A53 and memory controller.
   - Additionally, `media_kit_player_adapter.dart` contained an aggressive keyword-matching watchdog that triggered `fallbackToSoftwareDecoder()` (`hwdec: 'no'`) on benign engine logs containing words like `"video"`, `"codec"`, or `"surface"`. A Quad-core Cortex-A53 cannot software-decode 4K HEVC 10-bit, causing massive ~50%+ frame drops.

---

## 2. Proposed Solution Architecture

```text
                                  User Action / Playback Event
                                              │
                      ┌───────────────────────┴───────────────────────┐
                      ▼                                               ▼
         [Transient Engine Warning]                        [Decoder Mode Setting]
                      │                                               │
      Is video actively playing/advancing?            ┌───────────────┼───────────────┐
            │                     │                   ▼               ▼               ▼
           YES                    NO               Hardware        Hardware        Software
            │                     │                (Direct)         (Copy)          (CPU)
      Ignore log /          Halt playback &     [mediacodec]   [mediacodec-copy]     [no]
      clear error card      show error card           │               │               │
                                                      └───────────────┼───────────────┘
                                                                      ▼
                                                          Persist in SharedPreferences
                                                          & dynamically setProperty
                                                          on mpv engine on the fly
```

### 2.1 Error State Machine Decoupling (`flutter_client/`)
- **Suppress False-Positive Engine Errors**:
  - In `media_kit_player_adapter.dart`, do not unconditionally mark `_state = PlayerPlaybackState.error` on transient log messages from `player.stream.error`.
  - Only mark error if the player has actually stopped or failed to open.
- **Active Playback Self-Healing in `player_screen.dart`**:
  - In the position listener, if position is actively progressing (`pos > baselinePos`) or the controller reports playing, immediately clear `_errorMessage = null` and ensure `_state != PlayerPlaybackState.error`.
  - In `hasError` calculation: A fatal error card must NEVER be shown if the controller is actively playing or advancing position.
  - Allow dismissal: If an error card does appear, allow tapping outside or pressing Back to dismiss it if media is playing.

### 2.2 Configurable Decoder Modes & Zero-Copy Hardware Acceleration
- **Define `DecoderMode` Enum**:
  - `hardwareDirect`: `mediacodec` (Android) / `auto` (Desktop/iOS). Zero-copy direct Surface rendering. Completely bypasses the CPU memory bus, ideal for Fire TV Stick 4K and Android TV.
  - `hardwareCopy`: `mediacodec-copy` (Android). Compatible fallback mode.
  - `software`: `no`. Pure CPU decoding via libavcodec.
  - `auto`: Automatically selects `hardwareDirect` on Android TV / Fire TV and Android devices.
- **Remove Aggressive Software Fallback**:
  - Eliminate the generic keyword matcher in `player.stream.error` that unexpectedly demoted hardware decoding to CPU software decoding.
  - Only fall back if the first frame watchdog genuinely times out without rendering.
- **In-Player Decoder Mode Selector**:
  - Expose a Decoder Mode sheet / modal accessible from Player Controls (under Settings or via a dedicated "Decoder" / "Acceleration" button).
  - Users can switch on the fly between **Hardware (Direct)**, **Hardware (Compatible)**, and **Software (CPU)**.
  - When switched, invoke `await (player.platform as dynamic).setProperty('hwdec', mode)` and reload the stream at the current position.
  - Persist the selection in `SharedPreferences` so that Fire TV Stick 4K defaults to zero-copy direct hardware decoding.

---

## 3. Scope of Changes

### Modifying:
- `flutter_client/lib/features/player/data/media_kit_player_adapter.dart`:
  - Support `decoderMode` configuration and dynamic switching (`setDecoderMode`).
  - Default Android to `mediacodec` (zero-copy) instead of `mediacodec-copy`.
  - Sanitize `player.stream.error` listener to avoid falsely declaring fatal errors or triggering unwanted CPU fallbacks.
- `flutter_client/lib/features/player/domain/player_controller_interface.dart`:
  - Add `decoderMode` getter and `setDecoderMode(DecoderMode mode)` interface method.
- `flutter_client/lib/features/player/presentation/screens/player_screen.dart`:
  - Auto-heal `_errorMessage` when playback advances.
  - Guard `hasError` so it never renders while video is playing.
  - Add Decoder Mode option into in-player settings menu / modal.
- `flutter_client/lib/features/player/domain/player_models.dart`:
  - Add `enum DecoderMode { hardwareDirect, hardwareCopy, software, auto }`.
- `flutter_client/test/features/player/`:
  - Add tests for decoder mode switching and error self-healing.

### Deliberately Not Modifying:
- Backend transcode pipeline (`rust/src/`): 4K transcode Job 1148 is actively running on RX 560X in the background and must not be interrupted.
- Web React SPA (`web/`): Web client uses HTML5 `<video>` / HLS.js.

---

## 4. Exit Criteria

1. **No Error Flash or Persistent Popups**:
   - Starting *The Odyssey* on Android does not flash or persist "Playback Encountered an Error".
   - Seeking forward/backward and resuming does not trigger or leave any error card on screen while video plays.
2. **Smooth 4K Direct Playback on Fire TV Stick 4K**:
   - With `mediacodec` (zero-copy direct Surface decoding), memory bandwidth saturation is eliminated on MediaTek MT8695.
   - Hardware decoding remains active and is never demoted to CPU software decoding.
3. **User Configurable Decoder Setting**:
   - User can view and change Decoder Mode (Hardware Direct vs Hardware Copy vs Software CPU) in the player UI.
   - Selection persists across app launches.
4. **4-Pillar Verification Passes**:
   - `flutter analyze` passes with 0 issues.
   - `flutter test` passes 100%.

---

## 5. Risks & Mitigations

- **Risk**: Some low-end or customized Android ROMs have broken `mediacodec` surface rendering.  
  **Mitigation**: Users can easily switch to `Hardware (Compatible - mediacodec-copy)` or `Software (CPU)` directly from the in-player settings menu, and the choice is remembered.
- **Risk**: Hitting seek or error during stream reload when switching decoders.  
  **Mitigation**: Save current playback position before switching `hwdec` property, pause, apply property, and resume smoothly at the saved timestamp.

---

## 6. Open Decisions for User

1. **Default Decoder Mode on Android/Fire TV**:
   - **Option A (Recommended)**: Default to **Hardware (Direct - `mediacodec`)** for zero-copy high performance on 4K, with user option to switch to Compatible or Software.
   - **Option B**: Keep **Hardware (Compatible - `mediacodec-copy`)** by default and let user manually switch to Direct.
2. **Setting Placement**:
   - **Option A (Recommended)**: In the in-player Quick Actions / Settings modal alongside Subtitles and Quality, labeled "Decoder / Hardware Acceleration".
   - **Option B**: Dedicated icon in the player controls row.
