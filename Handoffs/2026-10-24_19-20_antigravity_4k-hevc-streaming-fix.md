# Session Handoff: 4K HEVC Streaming & Smart Direct Play Optimization

**Date & Time:** 2026-10-24 19:20 IST  
**Agent:** Antigravity  
**Branch:** `fix/issue-14-user-reported-faults`  
**Workspace:** `E:\MediaServer`  
**Related Documents:**
- Plan: [`docs/PLAN_4K_HEVC_STREAMING_FIX.md`](../docs/PLAN_4K_HEVC_STREAMING_FIX.md)
- Walkthrough: [`docs/WALKTHROUGH_4K_HEVC_STREAMING_FIX.md`](../docs/WALKTHROUGH_4K_HEVC_STREAMING_FIX.md)
- Current Issues: [`docs/Current issues.md`](../docs/Current%20issues.md)
- Project Status: [`docs/PROJECT_STATUS.md`](../docs/PROJECT_STATUS.md)

---

## 1. What Was Accomplished

1. **Problem Investigation & Diagnosis:**
   - Addressed user-reported failure where 4K HEVC movie (*Ghost in the Cell*) failed or stalled completely when streaming over HLS at 2160p on an Android phone, while 1440p (2K) and lower resolutions streamed smoothly, and native Direct Play 4K also played smoothly.
   - Diagnosed that mobile hardware decoders on Qualcomm Snapdragon 8 Gen 1 (`taro`) support 4K HEVC in hardware (`c2.qti.hevc.decoder`), but lack hardware decoding support for 4K H.264 (AVC).
   - The server previously encoded all HLS tiers using `h264_amf`. When playing 4K H.264, MediaCodec rejected the stream or dropped to CPU software decoding (`libavcodec`), which saturated the mobile CPU at 100% and froze playback.
2. **Backend Dual-Codec HLS Transcoding (`rust/src/services/`):**
   - In `gpu_service.rs`, `GPUWorkerConfig::get_ffmpeg_video_args()` was upgraded to emit **HEVC** (`hevc_amf`, `hevc_vaapi`, `libx265`) with canonical MP4 FourCC `-tag:v hvc1` for tiers \(\ge 2160\text{p}\), while preserving universal H.264 (`h264_amf`) for \(\le 1440\text{p}\).
   - In `hls_service.rs`, `STANDARD_QUALITIES` was updated to advertise `CODECS="hvc1.1.6.L153.B0,mp4a.40.2"` for 2160p.
   - In `routes/transcode.rs`, `start_transcode_handler()` was fixed to pass `force = true` when a quality cache is missing on disk so purged tiers re-transcode properly.
3. **Smart 4K Direct Play Routing in Flutter Client (`flutter_client/`):**
   - In `player_media_resolver.dart`, enhanced `resolveQualityUrl()`: when a movie is native 4K and `mode == PlaybackMode.directPlay`, selecting 2160p cleanly routes directly to `/media/<filename>` RFC 7233 byte-range stream for instantaneous playback and zero server GPU load.
   - In `player_screen.dart`, added `_isNative4k` dimension detection, `'4K DIRECT'` badge, and HUD toast feedback.
   - In `quality_selector_sheet.dart`, refined quality option titles and subtitles.
   - Added `test/features/player/player_media_resolver_test.dart` (6/6 tests passing).
4. **Testing & Verification:**
   - Rust unit tests: 125/125 passing.
   - `gpu_service` unit tests: 4/4 passing (`hevc_amf`, `hvc1`, `libx265`, `hvc1.1.6.L153.B0`).
   - Flutter tests: `player_media_resolver_test.dart` (6/6 passing), `quality_selector_sheet_test.dart` (4/4 passing).
   - Android API contract probe: 22/22 endpoints passing.
   - Live 2160p chunk probe: verified `hevc_amf` with FourCC `hvc1 (0x31637668)` at 3840x2160.
   - Service state: `MediaServerRust` (8000), `MediaServerPG` (5432), `MediaServerCaddy` (80/443) running and healthy.

---

## 2. Modified Files

- `rust/src/services/gpu_service.rs`
- `rust/src/services/hls_service.rs`
- `rust/src/routes/transcode.rs`
- `flutter_client/lib/features/player/infrastructure/player_media_resolver.dart`
- `flutter_client/lib/features/player/presentation/player_screen.dart`
- `flutter_client/lib/features/player/presentation/widgets/quality_selector_sheet.dart`
- `flutter_client/test/features/player/player_media_resolver_test.dart`
- `docs/PLAN_4K_HEVC_STREAMING_FIX.md`
- `docs/WALKTHROUGH_4K_HEVC_STREAMING_FIX.md`
- `docs/Current issues.md`
- `docs/PROJECT_STATUS.md`

---

## 3. Immediate Next Steps

- User can test playing *Ghost in the Cell* on their Android phone (`192.168.1.6:40283`):
  - Selecting 4K / Direct Play will stream effortlessly in full native quality.
  - Selecting 2160p HLS stream will now decode using hardware-accelerated HEVC (`c2.qti.hevc.decoder`) without buffering stalls.
- Stage and commit the clean changes to git branch `fix/issue-14-user-reported-faults`.
