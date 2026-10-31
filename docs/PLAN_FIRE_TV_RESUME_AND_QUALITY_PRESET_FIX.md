# Implementation Plan: Fix Fire TV Resume & Transcode Quality Presets

## Executive Summary
When playing *Verity* on the Fire TV Stick 4K (Android client) under account `anis7t@gmail.com`:
1. Navigating back and reopening the movie starts playback at `0:00` instead of resuming from the saved position (e.g., 5899s).
2. Quality presets (1080p, 720p, 480p, 360p) fail to play or stall, whereas native Direct Play works smoothly.

This plan resolves the underlying backend database type mismatch, stabilizes the client's HLS stream switching and hardware-to-software decoder fallback, and hardens AMF GPU encoder parameters for Android MediaCodec compliance.

---

## Root Causes Identified

### 1. Resume Failure (Backend SQLx Type Mismatch)
- **Database Schema**: In PostgreSQL (`media_server`), `progress.position` and `progress.duration` are defined as `FLOAT4` (`real`).
- **Backend Bug**: In `rust/src/services/catalog/movie_service.rs` (`list_movies` and `get_movie_details`):
  ```rust
  let position: f64 = r.try_get("position").unwrap_or(0.0);
  let duration: f64 = r.try_get("duration").unwrap_or(0.0);
  ```
  SQLx's PostgreSQL driver returns a `DecodeError(MismatchedType)` when attempting to decode a `real` (`f32`) column directly into `f64`. Because `.unwrap_or(0.0)` is used, SQLx silently swallows the error and sets `position = 0.0` and `duration = 0.0` for **every** movie in `/api/movies` and `/api/movie/{filename}`.
- **Client Impact**: In `flutter_client/.../movie_details_screen.dart`, line 749 evaluates `hasProgress = movie.position > 10`. Because `position` was returned as `0.0`, `hasProgress` was always `false`, showing only "Play Movie" starting at `Duration.zero` rather than "Resume (from X:XX)".

### 2. Transcode Quality Presets Failing (Client & Transcoder Incompatibilities)
- **AMD AMF SPS Level Unspecified**: In `rust/src/services/media_pipeline/gpu_service.rs`, `h264_amf` encodes chunks without explicit profile and level flags (`-profile:v high -level 4.1 -pix_fmt yuv420p`). The AMD driver marks SPS with `level: -99`, causing Android MediaCodec on Fire TV Stick (MediaTek/PowerVR) to reject the stream or fail hardware decoder initialization.
- **MediaKit Completer Lifetime Bug**: In `media_kit_player_adapter.dart`, `videoController.waitUntilFirstFrameRendered` only completes once. When switching quality to HLS, `.then()` fires immediately on the previously completed future, cancelling the 4-second timeout. If MediaCodec locks or fails on the HLS stream, `fallbackToSoftwareDecoder()` never fires.
- **Sequential HLS Segment Fetch on Startup**: In `media_kit_player_adapter.dart`, passing `Media(url, start: currentPos)` on an HLS playlist causes libmpv's HLS demuxer to sequentially request chunks from chunk 0 over HTTP rather than seeking after demuxing, stalling on low-memory Fire TV sticks.

---

## Scope of Work

### Component 1: Rust Backend Catalog Service (`rust/src/services/catalog/movie_service.rs`)
1. In `list_movies` (queries at lines 42, 65, 91) and `get_movie_details` (queries at lines 273, 301, 330):
   - Explicitly cast progress values in SQL: `COALESCE(p.position, 0.0)::DOUBLE PRECISION as position, COALESCE(p.duration, 0.0)::DOUBLE PRECISION as duration`.
2. In row decoding (lines 146-147 and 393-394):
   - Adopt resilient fallback decoding matching `progress_service.rs`:
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

### Component 2: AMD AMF Transcoder Parameters (`rust/src/services/media_pipeline/gpu_service.rs`)
1. For `h264_amf`, inject standard Android-compatible flags:
   - `-profile:v high`
   - `-level 4.1`
   - `-pix_fmt yuv420p`
2. For `hevc_amf`, ensure standard tags and pixel formats (`-tag:v hvc1 -profile:v main`).

### Component 3: Flutter Player Adapter (`flutter_client/lib/features/player/data/media_kit_player_adapter.dart`)
1. Reset `_firstFrameRendered = false` on every `open(...)` call and track stream-level frame rendering (e.g. listening to `player.stream.position > Duration.zero` or video dimensions), maintaining the 4-second fallback timer reliably across quality switches.
2. Expand error string matching in `player.stream.error` listener to catch all Android MediaCodec and surface initialization errors.
3. For HLS streams (`.m3u8`), avoid passing `start: startPosition` directly inside `Media(...)`; instead open the stream and dispatch `player.seek(startPosition)` once duration/tracks initialize, preventing libmpv chunk-fetch storms.

### Component 4: Cache Refresh for *Verity*
1. Purge the existing HLS transcode directory for *Verity* (`E:\MediaServer\cache\hls\b21b19570b9595b52af09d004e2daa8dc57163b4f38a516d6353a6a24d9aa0d4`) and trigger a fresh transcode with the compliant H.264 profile/level.

---

## Exit Criteria
1. `GET /api/movie/Verity...` with user session cookie returns:
   - `position`: actual watch position (e.g. `5899.0` or latest) > 0.
   - `duration`: `7256.834` > 0.
   - `percent`: ~81.3% > 0.
2. In the Flutter client on Fire TV, opening *Verity* displays the "Resume (from 1:38:19)" button alongside "Play from Beginning", and resuming starts precisely at that timestamp.
3. Selecting quality presets (1080p, 720p, 480p, 360p) on Fire TV transitions smoothly without stalling or black screens, falling back cleanly to software decoding if hardware decoding encounters an issue.
4. All existing tests pass:
   - `cargo test --manifest-path rust/Cargo.toml -- --test-threads=1`
   - `python scripts/probe_android_api.py`
   - `flutter analyze` & `flutter test` in `flutter_client`

---

## Risks & Mitigations
- **Risk**: AMF encoder flags (`-profile:v high -level 4.1`) might be rejected by specific AMD driver versions.
  - **Mitigation**: `-profile:v high` and `-level 4.1` are universal H.264 standards supported by all AMD AMF driver versions. We will verify using a test command before finalizing.
- **Risk**: Purging HLS cache removes transcoded chunks.
  - **Mitigation**: Direct Play remains 100% available at all times; background transcode regenerates valid chunks quickly across dual GPUs.

---

## Open Decisions
None. The changes align strictly with established project invariants, the 100% Rust + React architecture, and existing database contracts.
