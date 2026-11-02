# Implementation Plan: Seekbar Timeline & Frame Preview Alignment Fix

**Document:** `docs/PLAN_SEEKBAR_TIMELINE_AND_PREVIEW_ALIGNMENT_FIX.md`  
**Date:** 2026-11-02  
**Author:** Antigravity  

---

## 1. Executive Summary & Problem Analysis

### Background & Observed Behavior
With the server-side offset-slicing fix deployed in Release 1.4.6, in-flight quality switching and seeking now **play immediately without freezing** and without demuxer rapid-scan flooding. However, on any seek or quality switch:
1. **The seek bar resets to `0:00`** and counts upward from zero, even though playback is actually running from the seeked time (e.g., `1:00:14`).
2. **The total duration on the seek bar shrinks** to the remaining duration of the slice (e.g. `0:31` or `30:00`) instead of the true movie duration (e.g. `1:30:48`).
3. **Frame preview hover shows wrong thumbnails**: because frame index calculation relies on `_transportDuration` and `target`, the thumbnail generator clamps to the small slice range instead of the absolute movie timeline.

### Root Cause
In `MediaKitPlayerAdapter`:
```dart
@override
Stream<Duration> get positionStream => _baseTimelineOffset == Duration.zero
    ? player.stream.position
    : player.stream.position.map((pos) => pos + _baseTimelineOffset);

@override
Stream<Duration> get durationStream => _baseTimelineOffset == Duration.zero
    ? player.stream.duration
    : player.stream.duration.map((d) => d > Duration.zero ? d + _baseTimelineOffset : d);
```
1. `PlayerScreenState.initState()` subscribes to `_controller.positionStream` and `_controller.durationStream` once upon screen initialization.
2. At `initState()`, `_baseTimelineOffset` is `Duration.zero`.
3. The getter's ternary condition evaluated `_baseTimelineOffset == Duration.zero` as `true` and returned `player.stream.position` and `player.stream.duration` directly.
4. When `open()` or `seek()` was subsequently called, `_baseTimelineOffset` changed to `3614s`. But the listener was already bound directly to raw `player.stream.position` (which counts `0s, 1s, 2s...` from the start of the sliced stream).
5. In addition, when `libmpv` loads a sliced HLS playlist starting at `3614s` of a `3645s` movie, `player.state.duration` reports only the duration of the sliced playlist (`31s`). When `_baseTimelineOffset` was bypassed, `PlayerScreen` received `31s` as total duration.

---

## 2. Proposed Architecture & Scope of Changes

### A. Dedicated Broadcast Controllers in `MediaKitPlayerAdapter`
1. Replace getter-level stream mapping with dedicated broadcast stream controllers:
   ```dart
   final _positionController = StreamController<Duration>.broadcast();
   final _durationController = StreamController<Duration>.broadcast();
   ```
2. In `_initStreams()`:
   ```dart
   _subscriptions.add(player.stream.position.listen((pos) {
     _positionController.add(pos + _baseTimelineOffset);
   }));

   _subscriptions.add(player.stream.duration.listen((d) {
     if (d > Duration.zero) {
       final total = _totalKnownDuration ?? (d + _baseTimelineOffset);
       _durationController.add(total);
     }
   }));
   ```
3. Expose streams cleanly:
   ```dart
   @override
   Stream<Duration> get positionStream => _positionController.stream;

   @override
   Stream<Duration> get durationStream => _durationController.stream;
   ```
4. Track `_totalKnownDuration`:
   - When a full stream (Direct Play or non-sliced HLS) reports its duration, record `_totalKnownDuration = d`.
   - On subsequent quality switches or seeks, preserve `_totalKnownDuration` so the seekbar always displays the true full movie duration.

### B. Immediate Position & Duration Sync on `open()` and `seek()`
1. In `open()`:
   - When `hasStartPosition` is true:
     - Update `_baseTimelineOffset = startPosition`.
     - Immediately emit `_positionController.add(startPosition)`.
     - If `_totalKnownDuration != null`, immediately emit `_durationController.add(_totalKnownDuration!)`.
2. In `seek(Duration position)`:
   - When re-opening sliced HLS streams at `position`:
     - Immediately emit `_positionController.add(position)`.
     - Re-open with `startPosition: position`.

### C. Frame Preview & Transport Alignment in `PlayerScreen`
1. Ensure `_duration` is never overwritten with `Duration.zero` once a valid duration is known:
   ```dart
   _subscriptions.add(_controller.durationStream.listen((d) {
     if (!mounted) return;
     if (d > Duration.zero) {
       setState(() => _duration = d);
     }
   }));
   ```
2. With `_transportDuration` reflecting the full movie duration and `_transportPosition` reflecting absolute time:
   - `_computeFrameIndex(target)` accurately maps `seconds / interval` across the entire movie duration.
   - Seekbar thumb and hover bubbles display the true timestamp (`1:00:14 / 1:30:48`) and true preview images.

---

## 3. Deliberately Out of Scope
- No changes to the Rust backend playlist slicing logic (which has been proven 100% working and RFC 8216 compliant).
- No changes to Direct Play byte-range streaming.
- No changes to `/api/*` contracts or database schema.

---

## 4. Exit Criteria & Checkable Verification
1. **Automated Tests**:
   - `flutter analyze` in `flutter_client` passes with 0 warnings/errors.
   - `flutter test` in `flutter_client` passes with 100% success (all 421+ tests).
   - Dedicated unit tests verify `MediaKitPlayerAdapter` emits `pos + _baseTimelineOffset` and preserves full duration after quality change and seek.
2. **Live Device Verification on Phone via Wireless ADB (`192.168.1.6:37603`)**:
   - Open *Verity* on Direct Play at e.g. `3:22`.
   - Switch quality to `1080p` HLS:
     - Playback continues seamlessly.
     - Seek bar shows `3:22` (not `0:00`).
     - Total duration shows `1:30:48` (not `1:27:26`).
   - Seek forward to `50:00` or `1:00:14`:
     - Seek bar immediately reflects `50:00` or `1:00:14`.
     - Hovering/scrubbing displays the exact frame preview matching that scene.
     - Time HUD displays `1:00:14 / 1:30:48`.

---

## 5. Risks & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| **StreamController Lifecycle**: Unclosed stream controllers causing memory leaks on player dispose. | Memory leak over long sessions. | Close `_positionController` and `_durationController` inside `dispose()`. |
| **Duration Jitter**: If `libmpv` temporarily reports `Duration.zero` on stream reload. | Seekbar momentarily flashes 0:00 max. | Guard `_durationStream` so non-positive durations never overwrite known positive durations. |

---

## 6. Open Decisions for User Approval
1. **Duration Persistence Strategy**:
   - **Option 1 (Recommended)**: `MediaKitPlayerAdapter` stores `_totalKnownDuration` from the first loaded stream (or `item.duration` if provided) and ensures `durationStream` always reports the full movie duration across all subsequent sliced quality switches and seeks.
   - **Option 2**: Pass `mediaDuration` explicitly into `PlayerScreen` from the movie details metadata so `_duration` is never dependent on stream demuxing.
