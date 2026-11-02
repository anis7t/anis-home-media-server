# Handoff: HLS fMP4 Quality-Switch Seek Stall & Rapid Segment Scan Fix

**Timestamp (IST):** 2026-11-02 23:14  
**Author:** Antigravity  
**Repository:** `anis7t/media-server`  
**Stack:** 100% Rust (`:8000`), React 19 SPA (`web/dist/`), PostgreSQL 18.4 (`MediaServerPG`)  

---

## 1. What was Completed in this Session
- **Investigated Demuxer Stall Mechanism:**
  - Verified why `libmpv` seeks to `segment_001923.m4s`: Database progress for *Verity* was stored at `3614.332s` (`1:00:14`), NOT `50:31` (`3031s`). `segment_001923.m4s` spans `3612.50s` to `3616.25s`, making the seek mathematically exact.
  - Verified segment index gaps across chunk boundaries (e.g. 1966 -> 1984): Allocated by `SEGMENTS_PER_CHUNK_STRIDE = 32` per 60s chunk. Timestamps in `tfdt` are continuous across gaps.
  - Identified the root cause in FFmpeg's `libavformat/mov.c` (FFmpeg Trac #7359 / #7485): Initial stream probing parses `segment_000000.m4s`, populating `sc->index_entries`. On post-probe seek to 3614s, `hls.c` jumps to segment 1923 without reinitializing `mov.c`'s sample index tables. `mov.c` returns `AVERROR_EOF`, causing `hls.c` to rapidly scan all 1,931 segments to EOF (580 MB transferred) with zero frames rendered.
- **Implemented Offset Slicing on Rust Backend:**
  - `rust/src/services/media_pipeline/hls_service.rs`: Added `HlsService::slice_playlist_at_offset(text: &str, start_sec: f64) -> String`.
  - `rust/src/routes/media_pipeline/hls.rs`: Extracted `HlsQuery` (`start: Option<f64>`, `offset: Option<f64>`) on `playlist.m3u8` requests. When `start_sec > 0.0`, returns the sliced playlist anchored directly at the target segment.
  - `rust/tests/integration/media_pipeline/hls_transcode_test.rs`: Added unit & integration tests (`test_hls_service_slice_playlist_at_offset` and `test_hls_playlist_query_start_slices`).
  - All 16 integration tests in `hls_transcode_test` pass with 100% success.
  - Rebuilt and restarted `MediaServerRust` Windows service with the optimized release binary.
- **Implemented Client-Side Timeline & Slice Integration:**
  - `flutter_client/lib/features/player/data/media_kit_player_adapter.dart`:
    - For HLS streams with `hasStartPosition`, appends `?start=${startPosition.inSeconds}` to the playlist URL.
    - Sets `start: null` (and native `start: 'none'`) so `libmpv` begins playback immediately at the start of the sliced stream without post-probe demuxer seeking.
    - Added `_baseTimelineOffset` mapping for `positionStream`, `durationStream`, `position`, and `duration` so the player UI displays absolute movie time.
    - Updated `seek()` for HLS streams to re-open the sliced stream at the target timestamp.
  - Verified static analysis (`flutter analyze`: No issues found) and full test suite (`flutter test`: 421 passed, 0 failed).
- **Built & Deployed Release 1.4.6:**
  - Built and published Android production release **1.4.6** (versionCode **152**) via `scripts/release_android.py`.
  - Installed onto connected phone over wireless ADB (`192.168.1.6:37603`):
    - `adb install -r flutter_client/build/app/outputs/flutter-apk/app-release.apk` -> `Success`.
    - Dumpsys confirmed `versionName=1.4.6` and `versionCode=152`.
    - Launched app; Caddy logs verified active connection and heartbeats.

---

## 2. Key Artifacts & Files Modified
- Backend:
  - `rust/src/services/media_pipeline/hls_service.rs`
  - `rust/src/routes/media_pipeline/hls.rs`
  - `rust/src/services/media_pipeline/chunk_transcode.rs`
  - `rust/src/services/media_pipeline/transcode_worker.rs`
  - `rust/tests/integration/media_pipeline/hls_transcode_test.rs`
- Frontend / Client:
  - `flutter_client/lib/features/player/data/media_kit_player_adapter.dart`
  - `updates/version_registry.json`
- Documentation:
  - `docs/PLAN_HLS_FMP4_QUALITY_SWITCH_SEEK_STALL_FIX.md`
  - `docs/WALKTHROUGH_HLS_FMP4_QUALITY_SWITCH_SEEK_STALL_FIX.md`

---

## 3. Verification Protocol Executed
1. `scripts\cargo.bat test --manifest-path rust/Cargo.toml --test integration media_pipeline::hls_transcode_test` -> 16 passed, 0 failed.
2. `flutter analyze` in `flutter_client` -> No issues found (70.1s).
3. `flutter test` in `flutter_client` -> 421 passed, 0 failed.
4. Desktop `libmpv` seek reproduction -> Played smoothly: `Pos: 0s -> 1s -> 2s -> 3s -> 4s -> 5s` with sequential segment fetches (`001923` -> `001924` -> `001925`).
5. Live probe of `http://127.0.0.1:8000/hls/.../playlist.m3u8?start=3614.0` -> Correctly emitted sliced playlist starting at `segment_001923.m4s`.
6. Wireless ADB installation on phone (`192.168.1.6:37603`) -> Installed 1.4.6 (versionCode 152) successfully.

