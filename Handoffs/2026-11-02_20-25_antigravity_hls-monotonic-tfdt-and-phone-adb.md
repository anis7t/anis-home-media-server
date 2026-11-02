# Session Handoff: Unified Monotonic fMP4 HLS Pipeline & In-Flight Quality Switching

- **Date & Time:** 2026-11-02 20:30 IST
- **Author:** Antigravity
- **Primary Issue:** In the Android client (AHMS), watching *Verity* on Direct Play and switching quality in-flight to 1080p transcoded HLS at `50:31` resulted in a frozen player with 3–4 MB/s continuous download traffic and no playback.
- **Remote Device Wireless ADB Connection:** `192.168.1.6:37603` (Active & connected).

---

## 1. Executive Summary & Root Cause Breakdown

### The Transcode Fragmentation Mechanism
1. **Multi-Chunk Transcoding Engine**:
   - The transcode engine (`rust/src/services/media_pipeline/chunk_transcode.rs`) splits movie transcode jobs into autonomous 60-second chunks.
   - Each chunk was encoded by FFmpeg with the `fMP4` muxer. FFmpeg generated an `init_chunk_{id}.mp4` containing the chunk offset (e.g. 3000s) in an Edit List (`elst`) atom, but wrote Track Fragment Decode Time (`tfdt` box, `baseMediaDecodeTime`) starting at **`0`** in each `.m4s` segment.
2. **FFmpeg `libavformat/mov.c` Demuxer Invariant**:
   - When playing HLS streams with `#EXT-X-DISCONTINUITY` and multiple `#EXT-X-MAP:URI="init_chunk_{id}.mp4"` tags, FFmpeg reads the first `init_chunk_0.mp4` and parses its `moov` atom.
   - When fetching subsequent chunks (e.g. `init_chunk_50.mp4`), FFmpeg outputs:
     ```text
     [mov,mp4,m4a,3gp,3g2,mj2 @ ...] Found duplicated MOOV Atom. Skipped it
     ```
   - Skipping the duplicate `moov` atom causes FFmpeg to completely discard the `elst` box containing the chunk offset.
3. **Catastrophic Failure with `use_tfdt=0`**:
   - To bypass chunk-local resets, `flutter_client` had previously added `demuxer-lavf-o: seg_format_options=use_tfdt=0`.
   - With `elst` discarded and `tfdt` ignored, FFmpeg had zero timeline reference. It treated segments in Chunk 50 (3000–3060s) as timestamps **0s to 58s**.
   - Because the user was at `50:31` (`3031s`), `libmpv` dropped every arriving packet as outdated (`0s < 3031s`), scanning through all subsequent chunks at 3–4 MB/s until EOF without rendering any frames.

---

## 2. Completed Server & Client Implementations

### A. Server-Side Binary `tfdt` Stamping (`rust/src/services/media_pipeline/`)
1. **`stamp_chunk_segments_tfdt` in `chunk_transcode.rs`**:
   - Directly parses the ISOBMFF box hierarchy (`moof` -> `traf` -> `tfdt`).
   - Reads `track_id` from `tfhd`.
   - Calculates `chunk_base_ticks = (chunk_start_sec * timescale) as u64`.
   - Stamps the true movie presentation decode time (`chunk_base_ticks + local_decode_time`) into both 32-bit (v0) and 64-bit (v1) `tfdt` boxes.
   - Hooked directly into `transcode_worker.rs` upon chunk generation.
2. **Unified Master Playlist (`update_master_playlist`)**:
   - Emits a single canonical `#EXT-X-MAP:URI="init_chunk_0.mp4"` at the top of the playlist for fMP4 streams.
   - Strips all per-chunk `#EXT-X-DISCONTINUITY` and `#EXT-X-MAP` tags, producing an RFC 8216-compliant monotonic stream.

### B. Disk Cache Reconciliation
- Created and executed `scripts/reconcile_fmp4_cache.py`.
- Patched all 1,799 segments of *Verity* 1080p HLS cache with monotonic `tfdt` timestamps (using video timescale 12288 and audio timescale 48000) and rewrote `playlist.m3u8`.
- Verified keyframe decoding locally via `ffmpeg -ss 3028`: seeks in **0.15s** with zero errors.

### C. Client Player Cleanups (`flutter_client/`)
- Removed `_configureNativeDemuxer()` (`use_tfdt=0`) from `media_kit_player_adapter.dart`.
- Preserved clean codec flushing (`await player.stop()`) and instant seek anchoring (`setProperty('start', sec)`).
- Updated tests in `flutter_client/test/features/player/hls_seek_and_resume_test.dart`. All 121 player tests pass.
- Built and published Android Release **1.4.5** (versionCode **151**).

---

## 3. Real-Time Telemetry & Logcat Analysis on App 1.4.5

The user installed **1.4.5 (versionCode 151)** and re-tested in-flight quality switching on *Verity* at `50:31`. Playback still froze with 3–4 MB/s traffic.

### Telemetry from Live Logs:
1. **Caddy Access Log (`logs/caddy_access.log`)**:
   - At 14:55:12 UTC (20:25:12 IST), `libmpv` fetched `playlist.m3u8` and `init_chunk_0.mp4`.
   - It then fetched `segment_000000.m4s` and `segment_000001.m4s`.
   - Immediately after, instead of fetching `segment_001606.m4s` / `segment_001607.m4s` (which corresponds to `3031s` in `playlist.m3u8`), it jumped to `segment_001923.m4s` and rapidly downloaded segments `001923` through `003085` sequentially!
2. **Android Logcat (`pid_16640`)**:
   - `c2.qti.hevc.decoder` was cleanly torn down.
   - `c2.qti.avc.decoder` was created for the 1080p stream.
   - Because `libmpv` was scanning through segments 1923–3085, no decoded frames arrived at the surface.
   - After 8 seconds, `MediaKitPlayerAdapter` timed out:
     `[MediaKitPlayerAdapter] First frame not rendered after 8s; falling back to software decoding (hwdec: no)`
   - Switched to CPU software decoding, but `libmpv` continued looping through segments without playing.

### Why Did `libmpv` Jump to `segment_001923`?
- In `playlist.m3u8`, `segment_001923.m4s` has a cumulative playlist duration of **3630s (~60m 30s)**.
- At `50:31` (`3031s`), the actual segment is `segment_001607.m4s` (`cum_dur = 3032.5s`).
- When `_handleQualitySelected` in `player_screen.dart` calls `_controller.open(newUrl, startPosition: currentPos)`, what value was `currentPos` (`_transportPosition`)?
- Furthermore, in `media_kit_player_adapter.dart`:
  ```dart
  final sec = (startPosition.inMilliseconds / 1000.0).toStringAsFixed(3);
  await (nativePlatform as dynamic).setProperty('start', sec);
  ```
  And `Media(url, start: startPosition)` passes `startPosition` to `media_kit`.
  Does `media_kit`'s internal HLS demuxer calculate the seek offset using segment index or cumulative duration, or is `libmpv` reading `start` property as something unexpected?
- Also check whether `playlist.m3u8` contains gaps or non-uniform segment numbering (e.g. `segment_001966.m4s` followed by `segment_001984.m4s`), which could throw off `libmpv`'s internal segment index seek table.

---

## 4. Immediate Action Items for the Next Session

1. **Investigate `playlist.m3u8` Segment Number Discontinuities**:
   - Notice that segment numbering in `playlist.m3u8` jumps (e.g. 1966 -> 1984, 3022 -> 3040).
   - Verify whether chunk transcoder's segment numbering scheme or duration calculation in `playlist.m3u8` causes `libmpv`'s HLS demuxer to seek to the wrong segment offset.
2. **Test Direct `mpv` Playback from Command Line via ADB**:
   - With the phone connected at `192.168.1.6:37603`, test seeking directly on the stream using mpv or curl to inspect how libmpv resolves the seek target.
3. **Inspect `_transportPosition` in `player_screen.dart`**:
   - Add targeted logging or debug print on quality switch: what exact `currentPos` is passed to `_controller.open`?
4. **Phone Wireless ADB Details**:
   - Port and IP: `192.168.1.6:37603`.
   - Command: `adb connect 192.168.1.6:37603`.
