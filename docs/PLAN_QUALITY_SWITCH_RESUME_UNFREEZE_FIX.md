# Implementation Plan: Fix Quality Switch Resume & Unfreeze Playback

**Document Version:** 1.0.0  
**Target Date:** 2026-11-02  
**Target Release:** Android Client 1.4.3 (Build 149)  
**Author:** Antigravity Agent  

---

## 1. Executive Summary & Root Cause Analysis

### 1.1 Problem Statement
When playing a movie via Direct Play (e.g. *Verity* MKV/HEVC) and switching quality to a transcoded preset (e.g. 1080p HLS):
- The time displayed on the seek bar shows the timestamp where the user switched (e.g. 05:20).
- The player controls display the **Pause** icon (meaning Flutter's state is `PlayerPlaybackState.playing`).
- However, the video image and playback timer are **completely frozen**; playback does not advance.
- In contrast, when 1080p HLS is started from the beginning of the movie, playback and seeking work smoothly without indefinite buffering (verifying that the backend `#EXT-X-START:TIME-OFFSET=0` fix in Release 1.4.2 is 100% functional).

### 1.2 Root Cause Analysis
1. **`Media.start` Is Native-Ignored in `package:media_kit` 1.2.6:**
   In `media_kit`, the `start` parameter of `Media(url, start: startPosition)` is only evaluated on the Web target (`media_web.dart`). In native targets (`real.dart`), `Media.start` is omitted when generating the playlist for `libmpv`. Because `await player.seek(startPosition)` was removed in Release 1.4.2, `libmpv` was never commanded to navigate to the switch timestamp.
2. **`open(..., play: false)` vs Immediate `play()` Race / Deadlock:**
   In `MediaKitPlayerAdapter.open()`, the call was hardcoded to:
   ```dart
   await player.open(media, play: false);
   ...
   await player.play();
   ```
   Calling `player.open(media, play: false)` instructs `libmpv` to load the file in paused mode (`pause=yes`). Calling `player.play()` immediately after while `libmpv` is asynchronously initializing the demuxer and codec leads to a race condition where `libmpv` remains in paused state. Flutter's Dart wrapper, however, updates its state to `PlayerPlaybackState.playing`. The UI renders the Pause icon, but `libmpv` never outputs video frames.
3. **Watchdog Timer False Disarm on Stale Position:**
   In `MediaKitPlayerAdapter.open()`, the watchdog listener checked:
   ```dart
   if ((pos - baselinePos).abs() > const Duration(milliseconds: 200) || pos > Duration.zero)
   ```
   Because `player.state.position` was still holding `5:20` from the previous stream, `pos > Duration.zero` evaluated to `true` immediately on subscription, cancelling `_firstFrameTimeout` before the new stream even started loading.

---

## 2. Proposed Architecture & Solution

1. **Thread `play: wasPlaying` into `PlayerControllerInterface.open()`:**
   - Update `open(String url, {..., bool play = true})` in `PlayerControllerInterface`.
   - Pass `play: wasPlaying` directly into `player.open(media, play: play)`. This ensures `libmpv` is started natively in active playback mode when switching while playing, eliminating the pause/unpause race condition.
2. **Apply Native `start` Property & Seamless HLS Resume:**
   - Before invoking `player.open()`, set `start` on `player.platform`:
     ```dart
     if (startPosition != null && startPosition > Duration.zero) {
       await (nativePlatform as dynamic).setProperty(
         'start',
         '${startPosition.inMilliseconds / 1000.0}',
       );
     } else {
       await (nativePlatform as dynamic).setProperty('start', 'none');
     }
     ```
   - In addition, call `await player.seek(startPosition)` once the media is opened to guarantee accurate timestamp navigation across segmented HLS boundaries.
3. **Clean Watchdog Initialization:**
   - Guard the watchdog so it only evaluates position progression for the *new* stream and does not trigger on stale positions from the previous stream.
4. **Proper Demuxer Configuration:**
   - Ensure `_configureNativeDemuxer()` is properly awaited and does not dispatch unawaited futures during `open()`.

---

## 3. Scope of Changes

### In Scope
- [`flutter_client/lib/features/player/domain/player_controller_interface.dart`](file:///e:/MediaServer/flutter_client/lib/features/player/domain/player_controller_interface.dart): Add `bool play = true` parameter to `open(...)`.
- [`flutter_client/lib/features/player/data/media_kit_player_adapter.dart`](file:///e:/MediaServer/flutter_client/lib/features/player/data/media_kit_player_adapter.dart):
  - Pass `play: play` into `player.open(media, play: play)`.
  - Set mpv native `start` property before `open()`.
  - Re-enable accurate `seek(startPosition)` on HLS.
  - Reset stale position in watchdog.
- [`flutter_client/lib/features/player/presentation/screens/player_screen.dart`](file:///e:/MediaServer/flutter_client/lib/features/player/presentation/screens/player_screen.dart):
  - Pass `play: wasPlaying` in `_handleQualitySelected()`.
- [`flutter_client/test/features/player/`](file:///e:/MediaServer/flutter_client/test/features/player/): Unit and integration tests for `play` flag forwarding and start position setting.
- Release packaging: Build and publish Android release `1.4.3` (build 149) via `scripts/release_android.py`.

### Out of Scope (Deliberately Untouched)
- Rust backend (`rust/src/`): No changes needed. The HLS manifest `#EXT-X-START` fix is complete and verified.
- React frontend (`web/`): Unaffected.
- Database & PostgreSQL: Unaffected.

---

## 4. Exit Criteria

1. **Auto-Resume Verification:**
   - Switching from Direct Play to 1080p HLS while video is playing continues playing seamlessly from the exact same timestamp without freezing or requiring manual user interaction.
2. **Paused-State Preservation:**
   - If video is paused prior to switching quality, switching quality leaves the video paused at the same timestamp.
3. **Zero Seeking Buffering Stalls:**
   - Seeking forward and backward on 1080p HLS continues to function cleanly without indefinite buffering.
4. **Automated Test Validation:**
   - Flutter static analysis (`flutter analyze`) passes with 0 issues.
   - Flutter unit and player tests pass (100%).
5. **Production Release:**
   - APK release `1.4.3` (build 149) successfully built, registered in `version_registry.json`, and published for client update.

---

## 5. Risks and Mitigations

| Risk | Mitigation |
| :--- | :--- |
| `setProperty('start', ...)` unsupported on some custom mpv builds | Wrap in try/catch and supplement with `player.seek(startPosition)` after `open`. |
| Autoplay race condition if user wanted video paused | Strictly thread `wasPlaying` so `play: false` is respected when switching while paused. |
| Stale frame flash on quality change | `PlayerPlaybackState.opening` displays loading indicator or preserves smooth crossfade until the first frame of the new stream paints. |

---

## 6. Open Decisions

1. **Play State on Quality Switch:**
   - Option A (Recommended): Strictly maintain `wasPlaying` state (if playing, resume playing; if paused, stay paused).
   - Option B: Always auto-play on quality switch.
   *(Recommendation: Option A matches standard YouTube/Netflix behavior).*
