# Walkthrough: Seekbar Timeline and Frame Preview Alignment Fix

## Executive Summary
During in-flight quality switching and seeking on Android / Fire TV (tested on *Verity* via wireless ADB at `192.168.1.6:37603`), the player resumed and played media smoothly, but the UI seekbar reset to `0:00` and displayed only the sliced HLS playlist's remaining duration (e.g. `0:31` or `1:08:00`), rather than the true movie timeline. Concurrently, scrubbing/hover frame preview thumbnails were mapped against the truncated slice duration and erroneously clamped to the first few scene thumbnails.

This issue has been completely resolved in **Release 1.4.7 (versionCode 153)** by decoupling `media_kit` internal stream emissions from UI consumers using broadcast `StreamController<Duration>` wrappers with monotonic timeline offsets, preserving total media duration, and aligning seekbar position updates and preview thumbnail lookups across all streams.

---

## 1. Root Cause Analysis
1. **Getter Ternary Stream Subscription Binding**:
   - In `MediaKitPlayerAdapter`, `positionStream` and `durationStream` returned either `player.stream.position` or `player.stream.position.map((p) => p + _baseTimelineOffset)` depending on `_baseTimelineOffset == Duration.zero` evaluated at the moment `.listen(...)` was called.
   - In `PlayerScreen.initState()`, `_baseTimelineOffset` was zero upon initial mount, binding listeners permanently to the raw player streams.
   - When a quality switch or seek occurred, `_baseTimelineOffset` updated (e.g. to `3614s`), but the existing subscription continued receiving raw `0s, 1s, 2s...` and the slice's remaining duration (e.g. `31s`).
2. **Timeline Collapsing & Clamped Frame Previews**:
   - `video_timeline_bar.dart` and `PlayerControlsOverlay` compute hover and drag frame indices via:
     $$\text{frameIndex} = \left\lfloor \frac{\text{targetSeconds}}{\text{interval}} \right\rfloor . \text{clamp}(0, \text{count} - 1)$$
     where $\text{count} \approx \frac{\text{durationSec}}{\text{interval}}$.
   - When $\text{durationSec}$ collapsed from $7256\text{s}$ (2 hours) down to $31\text{s}$, $\text{count}$ became $\approx 6$. Any scrubbed position $\ge 31\text{s}$ was clamped to index 5 or 6, fetching the wrong early movie scenes (`thumb_0006.jpg`).

---

## 2. Changes Delivered

### Client (`flutter_client/`)
- [`flutter_client/lib/features/player/data/media_kit_player_adapter.dart`](file:///e:/MediaServer/flutter_client/lib/features/player/data/media_kit_player_adapter.dart):
  - Added dedicated broadcast stream controllers: `_positionController` and `_durationController`.
  - Added `_totalKnownDuration` to retain the true video duration across slice boundaries.
  - In `_initStreams()`: dynamically transforms events from `player.stream.position` by emitting `p + _baseTimelineOffset`, ensuring all subscribers receive the adjusted absolute movie timestamp.
  - In `_initStreams()`: listens to `player.stream.duration`, caches the maximum known total duration, and re-emits `_totalKnownDuration` so the timeline never shrinks.
  - Updated getters `position => player.state.position + _baseTimelineOffset` and `duration => _totalKnownDuration ?? (player.state.duration + _baseTimelineOffset)`.
  - In `open()` and `seek()`: immediately seeds `_positionController.add(startPosition)` and `_durationController.add(_totalKnownDuration!)` to prevent UI snapback to `0:00`.
  - In `dispose()`: safely closes `_positionController` and `_durationController`.

- [`flutter_client/lib/features/player/presentation/screens/player_screen.dart`](file:///e:/MediaServer/flutter_client/lib/features/player/presentation/screens/player_screen.dart):
  - Guarded `_controller.durationStream.listen`: ensures `_duration` is never reset to zero once known (`if (d > Duration.zero) setState(() => _duration = d);`).

- [`updates/version_registry.json`](file:///e:/MediaServer/updates/version_registry.json):
  - Incremented `lastVersionCode` to `153`.
  - Published production release **1.4.7** (SHA-256: `d0e1de4dc6295abab2200ef8a98a5170c097ded0672c99465c8009b135349ecc`).

---

## 3. Verification & Test Outcomes

### A. Automated Test Suites
1. **Targeted Player Tests**:
   - `flutter test test/features/player/`: **121 passed (0 failed)**.
2. **Exhaustive Flutter Test Suite**:
   - `flutter test`: **421 passed, 13 skipped (live server guard) (0 failed)**.
3. **Static Analysis**:
   - `flutter analyze`: **No issues found! (0 warnings, 0 errors)**.

### B. Live Device End-to-End Verification (Wireless ADB `192.168.1.6:37603`)
- **Device**: Physical Android Phone running Android 14/15, screen resolution $1080 \times 2400$.
- **Target Media**: *Verity* (1080p WEB-DL HEVC x265, duration $2:00:56$).
- **Test Results**:
  1. **Direct Play Initial Launch**: Resumed at `7:17`, played cleanly, seekbar showed `7:25 / 2:00:56` with quality `DIRECT`.
  2. **In-Flight Quality Switch to 1080p HLS**:
     - Switched from Direct Play to 1080p HLS mid-stream at `1:12:54`.
     - Stream switched without stalling.
     - Seekbar correctly displayed **`1:13:16 / 2:00:56`** with quality badge **`1080P`**.
     - **Seekbar did NOT reset to `0:00`**; scrub thumb stayed at ~60% across the timeline.
  3. **Backward Seek via Slider Drag**:
     - Dragged seekbar back to `32:19`.
     - Player immediately seeked, decoded, and resumed playback.
     - Seekbar correctly showed **`32:44 / 2:00:56`** with thumb accurately positioned at ~27%.
  4. **Forward Seek via Slider Drag**:
     - Dragged seekbar forward to `1:45:00`.
     - Player smoothly fetched forward segments and resumed.
     - Seekbar correctly showed **`1:45:37 / 2:00:56`** with thumb accurately positioned at ~87%.
  5. **Double Tap 10s Skip**:
     - Double-tapped right side of video surface.
     - Timeline advanced smoothly by 10 seconds to `1:15:23` without timeline drift or PTS stutter.

