# Implementation Plan: HLS fMP4 Quality-Switch Seek Stall & Rapid Segment Scan Fix

**Document:** `docs/PLAN_HLS_FMP4_QUALITY_SWITCH_SEEK_STALL_FIX.md`  
**Date:** 2026-11-02  
**Author:** Antigravity  

---

## 1. Executive Summary & Root Cause Analysis

### Background & Observed Bug
When watching *Verity* on Direct Play and performing an in-flight quality switch to 1080p transcoded HLS at position `1:00:14` (3614s):
1. Caddy access logs show `libmpv` fetching `playlist.m3u8` and `init_chunk_0.mp4`.
2. It fetches `segment_000000.m4s` and `segment_000001.m4s` during initial format probing.
3. `libmpv` then issues an internal seek to target timestamp `3614.0s` (`flags 32`).
4. In `playlist.m3u8`, the segment spanning 3614s is `segment_001923.m4s` (`3612.50s` to `3616.25s`).
5. FFmpeg's `libavformat/hls.c` demuxer fetches `segment_001923.m4s`.
6. However, `hls.c` immediately proceeds to fetch `segment_001924.m4s`, `segment_001925.m4s`, scanning rapidly through **all 1,931 subsequent segments** (over 580 MB of download traffic in seconds) until hitting the playlist EOF.
7. Zero video frames are demuxed or rendered. After 8 seconds, `MediaKitPlayerAdapter`'s `_firstFrameTimeout` fires, tearing down `c2.qti.avc.decoder` and permanently freezing the player.

### Findings on the Specific Questions Posed
1. **Why `segment_001923` instead of `segment_001607`?**
   - The user's active database progress for *Verity* on the phone was stored at **`3614.332s` (`1:00:14`)**, not `50:31` (`3031s`).
   - In `playlist.m3u8`, `segment_001923.m4s` spans `3612.50s` to `3616.25s`.
   - Seeking to `segment_001923.m4s` was **100% mathematically correct** for the playback position (3614s).
2. **Segment Index Continuity (e.g., 1966 -> 1984):**
   - The chunk transcoder allocates 32 index slots per 60s chunk (`SEGMENTS_PER_CHUNK_STRIDE = 32`).
   - At ~3.75s per segment, FFmpeg generates ~15 segments per chunk (`0..14`). The next chunk starts at `chunk_id * 32`.
   - Timestamp deltas across boundaries are continuous (e.g. `3720.0s - 3716.25s = 3.75s`). Under RFC 8216, this is valid, but the index jumps complicate external log auditing.
3. **The Core Demuxer Stall Mechanism:**
   - In `media_kit_player_adapter.dart`, `player.open(Media(url, start: startPosition))` instructs `libmpv` to start at `3614.0s`.
   - `libmpv` does NOT pass an input seek parameter to `avformat_open_input()`. Instead, it opens the HLS playlist from the beginning, probing `init_chunk_0.mp4` and `segment_000000.m4s` during `avformat_find_stream_info()`.
   - During probing, the sub-demuxer `libavformat/mov.c` parses `moof` from `segment_000000.m4s` and sets up internal sample index tables (`sc->index_entries` and `sc->current_sample`).
   - When `libmpv` executes the subsequent seek to 3614s, `hls.c` updates its target segment to `segment_001923.m4s`.
   - **Crucially, `hls.c` does NOT flush or re-initialize `mov.c`'s sample index tables.**
   - When reading `segment_001923.m4s`, `mov.c` attempts to read `sc->current_sample` using the closed byte offsets from `segment_000000.m4s`, immediately returning `AVERROR_EOF`.
   - `hls.c` treats `AVERROR_EOF` as segment completion and immediately fetches the next segment. Every subsequent segment also fails in `mov.c`, causing the client to scan all segments to EOF with zero frames decoded (`got EOF with no data before it`).
4. **Empirical Verification:**
   - In our desktop reproduction test, when an HLS playlist was provided that **starts directly at the target segment (1923)**, `mov.c` initializes its sample tables directly from segment 1923 during probe. **Playback starts immediately in 0.5s and plays smoothly with zero stalls!**

---

## 2. Proposed Architecture & Scope of Changes

### A. Server-Side: Offset-Sliced HLS Playlists (`GET /hls/.../playlist.m3u8?start=<seconds>`)
To eliminate the `mov.c` seeking bug in `libavformat`:
1. In `rust/src/routes/media_pipeline/hls.rs`:
   - Parse optional `start` / `offset` query parameter on `playlist.m3u8` requests (e.g., `?start=3614.0` or `?offset=3614.0`).
   - If `start` is provided and `> 0.0`:
     - Locate the segment in the playlist that spans `start` (calculating cumulative `#EXTINF` duration).
     - Slice the playlist so that the very first `#EXTINF` segment is the segment containing the seek point.
     - Emit the playlist with `#EXT-X-MEDIA-SEQUENCE:<first_seg_index>`, `#EXT-X-START:TIME-OFFSET=0`, and the canonical `#EXT-X-MAP:URI="init_chunk_0.mp4"`.
   - If `start` is omitted or `0.0`, serve the full playlist as usual.
2. In `rust/src/services/media_pipeline/hls_service.rs`:
   - Implement `slice_playlist_at_offset(content: &str, start_sec: f64) -> String`.
   - Ensure `#EXT-X-PLAYLIST-TYPE:VOD` is explicitly included when the transcode is complete, and `#EXT-X-PLAYLIST-TYPE:EVENT` when in-progress (satisfying GEMINI.md Rule 3).

### B. Client-Side: Passing Start Position via Playlist URL on Quality Switch
1. In `flutter_client/lib/features/player/data/media_kit_player_adapter.dart`:
   - When opening an HLS URL (`.m3u8`) with `hasStartPosition == true`:
     - Append query parameter `?start=${startPosition.inMilliseconds / 1000.0}` to the URL.
     - For HLS streams with `?start=...`, pass `start: null` to `Media()` (or `Duration.zero`) so `libmpv` does not execute a post-probe timeline seek into `mov.c`.
     - Direct Play streams (raw MKV/MP4) continue using native `Media(start: startPosition)` which supports RFC 7233 byte-range seeking without sub-demuxers.
   - Adjust `_frameWatchdogSub`:
     - Because the sliced playlist starts at the target segment, `player.stream.position` starts from `0s` (or relative to the slice). Adjust timeline display and progress reporting so the user sees the global movie position `3614s` seamlessly.
2. In `flutter_client/lib/features/player/presentation/screens/player_screen.dart`:
   - When switching quality in-flight (`_handleQualitySelected`), maintain current transport position and smoothly transition without triggering software decoder fallback.

### C. Client Watchdog Safety: Prevent Premature Decoder Kill
1. In `media_kit_player_adapter.dart`:
   - Extend `_firstFrameTimeout` to pause or reset while `player.state.buffering` is true.
   - Never kill hardware decoders (`fallbackToSoftwareDecoder()`) while network segment fetching is actively in-flight.

---

## 3. Deliberately Out of Scope
- We will NOT change the transcode engine back from fMP4 to MPEG-TS, as the monotonic `tfdt` stamping implemented in Phase 10.5 provides proper RFC 8216 compliance and CMAF compatibility.
- We will NOT alter Direct Play RFC 7233 byte-range streaming.
- We will NOT change the `/api/*` contract shapes for the Flutter/Fire TV client.

---

## 4. Exit Criteria & Checkable Verification
1. **Desktop Reproduction Test**:
   - `flutter_client/tool/test_verity_seek.dart` opening `Verity` 1080p HLS at `3614s` must begin playing within 1-2 seconds with `Pos: 3614s -> 3615s -> 3616s` and zero segment flooding in access logs.
2. **Phone Wireless ADB Quality-Switch Test**:
   - On the connected phone (`192.168.1.6:37603`), play *Verity* on Direct Play at `1:00:14`.
   - Switch quality to `1080p`.
   - Playback must resume within 2 seconds using hardware decoder `c2.qti.avc.decoder`.
   - Android logcat must confirm zero software decoder fallback events.
   - Caddy access logs must confirm `libmpv` downloads only segments `001923`, `001924`, etc. at normal playback cadence (1 segment per ~3.75s), NOT rapid EOF scanning.
3. **Automated Integration & Regression Tests**:
   - `cargo test --manifest-path rust/Cargo.toml -- --test-threads=1` passes.
   - `flutter analyze` and `flutter test` pass with 100% success.

---

## 5. Risks & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| **Timeline Position Offset in UI**: If HLS playlist is sliced from segment 1923, `libmpv` may report position `0s` instead of `3614s`. | Playback bar jumps to 0:00 on quality switch. | Use `#EXT-X-MEDIA-SEQUENCE` and `#EXT-X-START:TIME-OFFSET` or maintain client-side base offset in `MediaKitPlayerAdapter` to map local player position back to absolute movie timeline. |
| **Caching of Sliced Playlists**: Reverse proxy or browser might cache sliced playlist under the generic URL. | Quality switch or normal play receives wrong segments. | Query parameter `?start=...` differentiates cache keys, and `playlist.m3u8` responses declare `Cache-Control: no-cache, max-age=0`. |
| **In-Progress Transcode Slicing**: Slicing an actively transcoding stream near the live transcode edge. | Sliced playlist hits end of rendered segments. | Check available chunks before slicing; clamp slice target to rendered segments. |

---

## 6. Open Decisions for User Approval
1. **Timeline Presentation Mode**:
   - **Option 1 (Recommended)**: Server slices `playlist.m3u8?start=<sec>`, and `MediaKitPlayerAdapter` tracks the playback offset so the player UI displays the true absolute movie position (`1:00:14`), while `libmpv` receives the stream cleanly without demuxer seek crashes.
   - **Option 2**: Revert chunk transcode output container from fMP4 back to MPEG-TS (`.ts`), eliminating `mov.c` sub-demuxer bugs at the cost of slightly higher container overhead.
