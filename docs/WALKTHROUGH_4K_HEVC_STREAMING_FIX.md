# Walkthrough: 4K HEVC Streaming & Smart Direct Play Optimization

**Document:** `docs/WALKTHROUGH_4K_HEVC_STREAMING_FIX.md`  
**Date:** 2026-10-24  
**Feature/Bugfix:** 4K HEVC Streaming (*Ghost in the Cell*) & Smart Direct Play Routing  
**Platforms Verified:** Rust Backend (Axum), Flutter Android Client (`in.anisparvez.media_server_client` on Qualcomm Snapdragon 8 Gen 1 `taro`), Dual AMD GPUs (RX 560X discrete `dx11:1` + Vega 8 integrated `dx11:0`).

---

## 1. Executive Summary

A critical streaming defect was reported where a 4K HEVC title (*Ghost in the Cell*) failed or stalled completely when streaming over HLS (at 2160p) on Android mobile devices, while 2K (1440p) and lower resolutions streamed smoothly, and native Direct Play 4K also played smoothly.

### 1.1 Root Cause
1. **AVC vs HEVC 4K Hardware Decoder Limits:** Mobile SoCs (Qualcomm Snapdragon, MediaTek, Exynos, Google Tensor) dedicate 4K hardware decoding silicon exclusively to **HEVC (H.265), VP9, and AV1**. Their legacy H.264 (AVC) hardware decoders are hard-capped at 1080p (Level 4.2) or 1440p (Level 5.0).
2. **Server-Side Encoding:** The server previously encoded all HLS tiers using `h264_amf` (H.264 AVC) with non-standard SPS parameters (`level: -99`, `avc1.4d0433`). When the Android client opened a 3840x2160 H.264 stream, Android's `MediaCodec` rejected hardware decoding, forcing software decoding on the CPU (`libavcodec`). The CPU became saturated at 100%, causing massive frame drops and indefinite buffering stalls.
3. **Smart 4K Direct Play Routing:** When a movie is already native 4K and the client supports Direct Play (like the user's phone playing 4K HEVC in hardware), selecting 4K in the player unnecessarily triggered a server-side 4K-to-4K transcode instead of routing directly to the lossless, zero-overhead Direct Play bitstream.

---

## 2. Changes Made & Implementation Details

### 2.1 Backend: Dual-Codec HLS Transcoding Pipeline
- **`rust/src/services/gpu_service.rs`**:
  - Enhanced `GPUWorkerConfig::get_ffmpeg_video_args()`:
    - **Tiers \(\ge 2160\text{p}\) (4K):** Transcodes into **HEVC** using AMD AMF hardware encoder (`hevc_amf`), VAAPI (`hevc_vaapi`), or CPU (`libx265`). Emits canonical MP4 FourCC tag `-tag:v hvc1` for strict Apple HLS / Android MediaCodec conformance.
    - **Tiers \(< 2160\text{p}\) (1440p, 1080p, 720p, 480p, 360p):** Retains universal **H.264 (AVC)** (`h264_amf`, `h264_vaapi`, `libx264`) ensuring complete backward compatibility for legacy web browsers and low-power clients.
  - Added unit test suite covering AMF 4K (`hevc_amf` + `hvc1`), AMF <= 1440p (`h264_amf`), CPU 4K (`libx265`), and HLS codec strings.
- **`rust/src/services/hls_service.rs`**:
  - Updated `STANDARD_QUALITIES` 2160p entry to canonical Apple HLS / CMAF specification:
    `("2160p", 3840, 2160, 14000000, "hvc1.1.6.L153.B0,mp4a.40.2")`
  - Rebuilt master playlist dynamically advertising `hvc1` for 2160p and `avc1` for lower tiers.
- **`rust/src/routes/transcode.rs`**:
  - Updated `start_transcode_handler()`: passes `force = true` to `JobService::enqueue_with_priority()` when the requested quality playlist is not present on disk, ensuring purged or missing cache directories immediately trigger active transcoding.

### 2.2 Client: Smart 4K Direct Play Routing & UI Polish
- **`flutter_client/lib/features/player/infrastructure/player_media_resolver.dart`**:
  - Enhanced `resolveQualityUrl()` with `isNative4K` detection:
    - When `quality == '2160p'` (or `'4k'`) and `mode == PlaybackMode.directPlay` on a native 4K title, automatically routes to `/media/<filename>` RFC 7233 byte-range stream.
    - Provides **instant playback start**, **zero server GPU transcode overhead**, and **lossless bitstream fidelity**.
    - If `mode == PlaybackMode.hls` (direct play unsupported or disabled), cleanly resolves to `/hls/<filename>/2160p/playlist.m3u8` (now HEVC).
- **`flutter_client/lib/features/player/presentation/player_screen.dart`**:
  - Added `_isNative4k` getter inspecting video metadata dimensions.
  - Updated `_applyAuthoritativeMode` and `_handleQualitySelected` to pass `isNative4K: _isNative4k`.
  - Added HUD toast distinction: shows `"Quality: 4K Direct Play (Lossless)"` when direct routing is engaged.
  - Updated `_selectedQualityBadge` to display `'4K DIRECT'` when playing 4K direct stream.
- **`flutter_client/lib/features/player/presentation/widgets/quality_selector_sheet.dart`**:
  - Badged options clearly: `"Original (4K Direct Play - Lossless)"` and `"2160p (4K HEVC Stream)"` with `"HEVC stream"` subtitle.
  - Preserved custom option labels when provided by test ladders.
- **`flutter_client/test/features/player/player_media_resolver_test.dart`**:
  - Added dedicated unit test suite verifying `resolveQualityUrl` across source, auto, 2160p direct-play routing, 2160p HLS routing, and 1080p tiers.

---

## 3. Verification & Test Outcomes

### 3.1 Unit & Integration Test Suites
| Test Suite | Target | Status | Notes |
| :--- | :--- | :--- | :--- |
| **Rust Unit Tests** (`cargo test --lib`) | `gpu_service`, `hls_service`, etc. | **PASS (125/125)** | All tests green |
| **Rust GPU & 4K Tests** (`cargo test --lib services::gpu_service`) | `test_get_ffmpeg_video_args_*`, `test_hls_standard_qualities_*` | **PASS (4/4)** | Verified `hevc_amf`, `-tag:v hvc1`, and `hvc1.1.6.L153.B0` |
| **Flutter Resolver Tests** (`flutter test player_media_resolver_test.dart`) | `resolveQualityUrl` smart 4K routing | **PASS (6/6)** | Verified all routing branches |
| **Flutter Quality Sheet Tests** (`flutter test quality_selector_sheet_test.dart`) | `QualitySelectorSheet` UI rendering | **PASS (4/4)** | Verified options and badges |
| **Android API Contract Probe** (`python scripts/probe_android_api.py`) | All Android client endpoints | **PASS (22/22)** | Zero regressions |

### 3.2 Live Service & Media Validation
1. **Master Playlist Output (`/hls/<filename>/master.m3u8`):**
   ```m3u8
   #EXTM3U
   #EXT-X-VERSION:7
   #EXT-X-INDEPENDENT-SEGMENTS

   #EXT-X-STREAM-INF:BANDWIDTH=14000000,RESOLUTION=3840x2160,CODECS="hvc1.1.6.L153.B0,mp4a.40.2"
   2160p/playlist.m3u8

   #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=2560x1440,CODECS="avc1.640032,mp4a.40.2"
   1440p/playlist.m3u8
   ```
2. **Live Transcoded 2160p Chunk Probe (`init_chunk_0.mp4`):**
   ```json
   {
     "codec_name": "hevc",
     "codec_long_name": "H.265 / HEVC (High Efficiency Video Coding)",
     "profile": "Main",
     "codec_tag_string": "hvc1",
     "codec_tag": "0x31637668",
     "width": 3840,
     "height": 2160,
     "encoder": "Lavc63.1.101 hevc_amf"
   }
   ```
3. **Live Transcode Job Execution:**
   - Database job #776 transitioned from `queued` -> `running`.
   - Dual AMD GPUs actively generated `hevc_amf` segments (`segment_000000.m4s`, `segment_000001.m4s`, etc.) into `E:\MediaServer\cache\hls\...\2160p\`.
4. **Persistent Services Health:**
   - `MediaServerRust` compiled cleanly with `cargo build --release` in 1m 47s and is healthy on port 8000.
   - `MediaServerPG` active on port 5432.
   - `MediaServerCaddy` active on ports 80/443.
