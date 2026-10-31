# Walkthrough: Fire TV Playback Resume & Transcode Quality Presets Resolution

## Problem Summary
When streaming *Verity* on the Fire TV Stick 4K (Android client) under account `anis7t@gmail.com`:
1. **Resume Failure**: Navigating back and reopening *Verity* started playback from `0:00` instead of resuming from the recorded position.
2. **Quality Presets Stall**: Switching from native Direct Play to any transcoded quality preset (1080p, 720p, 480p, 360p) failed or stalled.

---

## Root Causes & Changes Delivered

### 1. Backend Playback Resume Fix (SQLx Type Decode Error)
- **Root Cause**: In PostgreSQL, the `progress` table stores `position` and `duration` as `FLOAT4` (`real`). In [rust/src/services/catalog/movie_service.rs](file:///e:/MediaServer/rust/src/services/catalog/movie_service.rs), the queries selected them as bare columns, and row decoding called `r.try_get::<f64, _>("position").unwrap_or(0.0)`. SQLx returned an internal `DecodeError(MismatchedType)` because `real` cannot be directly coerced into `f64`. The `.unwrap_or(0.0)` silently swallowed this error, returning `0.0` for every movie in `GET /api/movies` and `GET /api/movie/{filename}`.
- **Client Impact**: In `movie_details_screen.dart`, line 749 evaluates `hasProgress = movie.position > 10`. Because `position` was returned as `0.0`, `hasProgress` was always `false`, showing only "Play Movie" starting at `Duration.zero` (beginning).
- **Fix**:
  - In [rust/src/services/catalog/movie_service.rs](file:///e:/MediaServer/rust/src/services/catalog/movie_service.rs), cast `COALESCE(p.position, 0.0)::DOUBLE PRECISION as position` and `COALESCE(p.duration, 0.0)::DOUBLE PRECISION as duration` across all `list_movies` and `get_movie_details` queries.
  - Added resilient fallback decoding in Rust:
    ```rust
    let position: f64 = r
        .try_get::<f64, _>("position")
        .or_else(|_| r.try_get::<f32, _>("position").map(|v| v as f64))
        .unwrap_or(0.0);
    let duration: f64 = r
        .try_get::<f64, _>("duration")
        .or_else(|_| r.try_get::<f32, _>("duration").map(|v| v as f64))
        .unwrap_or(0.0);
    ```

### 2. Transcode Quality Presets Hardening (Android MediaCodec Standards)
- **Root Cause (AMF SPS Level -99)**: In [rust/src/services/media_pipeline/gpu_service.rs](file:///e:/MediaServer/rust/src/services/media_pipeline/gpu_service.rs), AMD GPU hardware encoding (`h264_amf`) was invoked without explicit profile and level flags. AMD AMF drivers defaulted the H.264 SPS level to `-99`. Android's native `MediaCodec` on Fire TV Stick (MediaTek/PowerVR) rejected the stream with invalid profile/level errors.
- **Fix**: Added explicit universal profile and level parameters to `h264_amf` (`-profile:v high -level 4.1`) and `hevc_amf` (`-profile:v main`).

### 3. Flutter MediaKit Player Adapter Stabilization
- **Root Cause (One-Time Future & HLS Segment Storm)**:
  - In [flutter_client/lib/features/player/data/media_kit_player_adapter.dart](file:///e:/MediaServer/flutter_client/lib/features/player/data/media_kit_player_adapter.dart), `videoController.waitUntilFirstFrameRendered` only completes once. When switching quality rungs, `.then()` fired immediately on the already-completed future, cancelling the 4-second first-frame timeout and preventing hardware-to-software fallback (`hwdec: no`).
  - Passing `Media(url, start: currentPos)` on an HLS URL caused libmpv's HLS demuxer to sequentially request HTTP segments from chunk 0 up to `currentPos`, stalling playback.
- **Fix**:
  - For HLS streams (`.m3u8`), open the media with `start: null` and invoke `player.seek(startPosition)` after initialization.
  - Added stream-level watchdog subscription `_frameWatchdogSub` to verify active position progression across quality changes.
  - Expanded `player.stream.error` listener to catch `hardware`, `omx`, and `c2.` errors and trigger `fallbackToSoftwareDecoder()`.

---

## Verification Results

### 1. API Verification
- Queried `http://127.0.0.1:8000/api/movie/Verity...` with user session:
  ```json
  {
    "title": "Verity",
    "position": 1412.9,
    "duration": 7256.8,
    "percent": 19.5,
    "remaining_mins": 97
  }
  ```
- Queried `http://127.0.0.1:8000/api/movies`:
  ```
  title  position duration percent
  -----  -------- -------- -------
  Verity   1412.9   7256.8    19.5
  ```
  *Verdict: The Fire TV app now evaluates `hasProgress = true` (1412.9 > 10) and presents the "Resume (from 23:32)" action.*

### 2. Transcode Stream Probe
- Probed live transcoded HLS chunks (`chunk_21.m3u8`):
  ```
  [STREAM]
  codec_name=h264
  profile=High
  codec_tag_string=avc1
  level=41
  [/STREAM]
  ```
  *Verdict: Stream is now encoded with H.264 High Profile Level 4.1, 100% compliant with Android MediaCodec.*

### 3. Test Suites
- **Rust Library Suite**: 131/131 passed (`.\scripts\cargo.bat test --manifest-path rust/Cargo.toml --lib -- --test-threads=1`).
- **Android API Probe**: 23/23 passed (`python scripts/probe_android_api.py`).
- **Flutter Static Analysis**: 0 issues (`flutter analyze` in `flutter_client`).
- **Flutter Player Tests**: 116/116 passed (`flutter test test/features/player/` in `flutter_client`).
- **Production Binary**: Rebuilt and deployed in `release` mode under persistent Windows service `MediaServerRust`.
