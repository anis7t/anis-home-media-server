# Walkthrough: HLS fMP4 Quality-Switch Seek Stall & Rapid Segment Scan Fix

**Document:** `docs/WALKTHROUGH_HLS_FMP4_QUALITY_SWITCH_SEEK_STALL_FIX.md`  
**Date:** 2026-11-02  
**Status:** 100% Implemented, Verified, and Deployed to Android Phone (1.4.6 / versionCode 152)  

---

## 1. Executive Summary & Root Cause Resolution

### The Problem
During playback of *Verity* on Direct Play, switching quality in-flight to 1080p transcoded HLS caused an indefinite freeze accompanied by continuous network download traffic (over 580 MB transferred within seconds).
Log inspection revealed:
1. `libmpv` fetched `playlist.m3u8` and `init_chunk_0.mp4`.
2. `libmpv` probed `segment_000000.m4s` during initial format probing via `avformat_find_stream_info`.
3. `libmpv` executed an internal seek to target timestamp `3614.0s` (`flags 32`).
4. FFmpeg's `libavformat/hls.c` demuxer fetched `segment_001923.m4s`.
5. However, the sub-demuxer `libavformat/mov.c` had already initialized its internal sample index tables (`sc->index_entries`) from `segment_000000.m4s`. Because `hls.c` does not reset `mov.c` on mid-stream jumps, `mov.c` failed to locate samples in the new segment and immediately returned `AVERROR_EOF`.
6. `hls.c` treated this as segment completion and immediately fetched the next segment, rapidly scanning all 1,931 subsequent segments to the playlist end (`got EOF with no data before it`), rendering zero frames and triggering hardware decoder teardown.

### Resolution: Server-Side Offset Slicing + Client Native Anchor
1. **Server-Side (`HlsService::slice_playlist_at_offset`)**:
   - `GET /hls/.../playlist.m3u8?start=<seconds>` or `?offset=<seconds>` slices the playlist so the very first segment emitted is the segment containing the seek point.
   - Declares `#EXT-X-MEDIA-SEQUENCE:<slice_idx>`, `#EXT-X-START:TIME-OFFSET=0`, `#EXT-X-MAP:URI="init_chunk_0.mp4"`, and `#EXT-X-PLAYLIST-TYPE:VOD`.
   - Because the target segment is the first segment in the playlist, `avformat_find_stream_info` anchors directly on the target segment during probing, completely bypassing the post-probe demuxer seek and eliminating the `mov.c` bug.
2. **Client-Side (`MediaKitPlayerAdapter`)**:
   - For HLS streams with a start position, the adapter appends `?start=${startPosition.inSeconds}` to the playlist URL and sets `start: null` (and native `start: 'none'`).
   - Maintains `_baseTimelineOffset` so `positionStream`, `durationStream`, `position`, and `duration` report the true absolute movie position and length to the UI seamlessly.
   - For in-flight seeks on HLS streams, re-opens the sliced stream at the new target position, ensuring smooth seeks without demuxer corruption.

---

## 2. Changes Summary

| Tier | Component / File | Description |
|---|---|---|
| **Rust Backend** | `rust/src/services/media_pipeline/hls_service.rs` | Implemented `HlsService::slice_playlist_at_offset(text: &str, start_sec: f64) -> String` to slice `#EXTINF` entries by cumulative duration while preserving `#EXT-X-MAP` and RFC 8216 header tags. |
| **Rust Backend** | `rust/src/routes/media_pipeline/hls.rs` | Added `HlsQuery` (`start: Option<f64>`, `offset: Option<f64>`). When requesting `playlist.m3u8`, calls `slice_playlist_at_offset` if `start_sec > 0.0`. |
| **Rust Backend** | `rust/src/services/media_pipeline/chunk_transcode.rs` | Added `stamp_chunk_segments_tfdt` to stamp monotonic `tfdt` decode times across chunks. |
| **Rust Backend** | `rust/src/services/media_pipeline/transcode_worker.rs` | Invokes `stamp_chunk_segments_tfdt` upon chunk generation. |
| **Rust Integration Tests** | `rust/tests/integration/media_pipeline/hls_transcode_test.rs` | Added integration tests `test_hls_service_slice_playlist_at_offset` and `test_hls_playlist_query_start_slices`. |
| **Flutter Client** | `flutter_client/lib/features/player/data/media_kit_player_adapter.dart` | Added `_baseTimelineOffset`, `?start=` query parameter passing, `start: null` for sliced HLS streams, timeline offset mapping for position/duration streams, and seek re-anchor. |
| **Flutter Release** | `updates/version_registry.json` | Published production release **1.4.6** (versionCode **152**). |

---

## 3. Verification & Test Outcomes

### A. Rust Integration Test Suite
Executed via `scripts\cargo.bat test --manifest-path rust/Cargo.toml --test integration media_pipeline::hls_transcode_test`:
```text
running 16 tests
test media_pipeline::hls_transcode_test::test_hls_and_transcode_options_cors ... ok
test media_pipeline::hls_transcode_test::test_hls_master_playlist_in_flight_503 ... ok
test media_pipeline::hls_transcode_test::test_hls_master_playlist_multi_tier_delivery ... ok
test media_pipeline::hls_transcode_test::test_hls_playlist_delivery_200_and_cors ... ok
test media_pipeline::hls_transcode_test::test_hls_playlist_in_flight_503_retry ... ok
test media_pipeline::hls_transcode_test::test_hls_playlist_query_start_slices ... ok
test media_pipeline::hls_transcode_test::test_hls_quality_tier_subpath_delivery ... ok
test media_pipeline::hls_transcode_test::test_hls_segment_delivery_m4s_and_init ... ok
test media_pipeline::hls_transcode_test::test_hls_segment_delivery_ts_and_range ... ok
test media_pipeline::hls_transcode_test::test_hls_segment_traversal_and_invalid_names_404 ... ok
test media_pipeline::hls_transcode_test::test_hls_service_detects_completed_tiered_transcode ... ok
test media_pipeline::hls_transcode_test::test_hls_service_slice_playlist_at_offset ... ok
test media_pipeline::hls_transcode_test::test_honest_target_duration_adjustment ... ok
test media_pipeline::hls_transcode_test::test_is_valid_segment_name ... ok
test media_pipeline::hls_transcode_test::test_transcode_cached_mp4_delivery ... ok
test media_pipeline::hls_transcode_test::test_transcode_uncached_returns_503_and_idle_status ... ok

test result: ok. 16 passed; 0 failed; 0 ignored; finished in 57.68s
```

### B. Flutter Static Analysis & Test Suite
- `flutter analyze`: **No issues found!** (ran in 70.1s).
- `flutter test`: **All 421 tests passed!** (13 skipped live-server tests).

### C. Live Server Slice & libmpv Playback Test
- Probed `GET /hls/Verity.../1080p/playlist.m3u8?start=3614.0`:
  - Returned `#EXT-X-MEDIA-SEQUENCE:903`
  - First segment: `segment_001923.m4s` (spanning 3612.50s to 3616.25s)
- Ran desktop reproduction test with `libmpv`:
  ```text
  PLAYBACK: Pos: 0s (342ms), Playing: true, Buffering: false
  PLAYBACK: Pos: 1s (1372ms), Playing: true, Buffering: false
  PLAYBACK: Pos: 2s (2372ms), Playing: true, Buffering: false
  PLAYBACK: Pos: 3s (3412ms), Playing: true, Buffering: false
  PLAYBACK: Pos: 4s (4412ms), Playing: true, Buffering: false
  PLAYBACK: Pos: 5s (5402ms), Playing: true, Buffering: false
  ```
- Demuxer log confirmed sequential fetching of `segment_001923.m4s`, `segment_001924.m4s`, `segment_001925.m4s`, etc. Zero segment flooding, zero EOF scanning.

### D. Production Deployment to Phone via Wireless ADB
1. Built release APK 1.4.6 / versionCode 152 via `scripts/release_android.py`.
2. Streamed and installed directly to phone over ADB (`192.168.1.6:37603`):
   ```text
   Performing Streamed Install
   Success
   ```
3. Verified installed package identity on phone:
   ```text
   versionCode=152 minSdk=24 targetSdk=36
   versionName=1.4.6
   ```
4. Launched app on phone; Caddy access logs confirmed device connection and active telemetry heartbeats.

