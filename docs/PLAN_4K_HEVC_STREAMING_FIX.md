# Implementation Plan: 4K HEVC Streaming & Smart Direct Play Optimization

**Document:** `docs/PLAN_4K_HEVC_STREAMING_FIX.md`  
**Date:** 2026-10-24  
**Target Issue:** 4K HEVC movie (*Ghost in the Cell*) fails/stalls on Android client when streaming 4K HLS, while 2K/1440p and Direct 4K play smoothly.

---

## 1. Problem Diagnosis & Root Cause Analysis

### 1.1 The Symptom
On the Android client (e.g., Vivo/iQOO `I2217` on Qualcomm Snapdragon 8 Gen 1 `taro`):
- **Direct 4K Play (`/media/...`)**: Streams and plays smoothly with zero stutters.
- **1440p (2K), 1080p, 720p HLS**: Streams and plays smoothly.
- **2160p (4K) HLS (`/hls/.../2160p/playlist.m3u8`)**: Stalls completely, fails to render, or drops all frames.

### 1.2 Root Causes Identified
1. **4K Codec Architecture Mismatch (H.264 vs HEVC):**
   - The server backend (`rust/src/services/gpu_service.rs`) currently uses `h264_amf` (AMD GPU hardware H.264/AVC encoder) unconditionally for all HLS resolution tiers, including 2160p.
   - The master playlist (`hls_service.rs`) advertises:
     `#EXT-X-STREAM-INF:BANDWIDTH=14000000,RESOLUTION=3840x2160,CODECS="avc1.640033,mp4a.40.2"`
   - In mobile silicon (Qualcomm, MediaTek, Samsung, Google), hardware video decoding for 4K is dedicated to **HEVC (H.265), VP9, and AV1**. Mobile SoCs almost universally lack hardware decoding support for 4K H.264 (AVC) or reject the AMF SPS parameters (AMF emits `level: -99`, non-standard SPS/VUI tags, and `avc1.4d0433`).
   - When the Android app's player (`media_kit` / `libmpv`) attempts to open 4K H.264, Android's `MediaCodec` rejects hardware decoding or fails, forcing software CPU decoding (`libavcodec`). On a mobile CPU, software-decoding 4K H.264 at 14 Mbps consumes 100% of CPU cores, dropping 95%+ frames and causing indefinite buffering stalls.
   - Conversely, **Direct Play 4K** serves the raw source file, which is native **HEVC Main 10**. The phone's hardware decoder (`c2.qti.hevc.decoder`) decodes 4K HEVC effortlessly at 60 fps with 0% CPU load.
2. **Quality Ladder UX Redundancy:**
   - In `QualitySelectorSheet` and `player_screen.dart`, when a movie's native resolution is 4K and direct play is supported, the user is offered both "Original (Direct Play)" and "2160p".
   - When users tap "2160p", the client sends a request to `/hls/<filename>/2160p/playlist.m3u8` instead of utilizing the pristine native 4K Direct Play stream. This needlessly forces server-side re-encoding of 4K to 4K on the host's dual GPUs and fails on mobile clients due to the H.264 codec mismatch.

---

## 2. Proposed Architecture & Solution

### 2.1 Backend: 4K HEVC fMP4 Transcoding (`hevc_amf`)
- **Dual-Codec HLS Ladder:**
  - **Tiers <= 1440p (1440p, 1080p, 720p, 480p, 360p):** Remain **H.264 (AVC)** (`h264_amf` / `h264_vaapi` / `libx264`). This preserves universal compatibility across legacy browsers and devices that lack HEVC support.
  - **Tier 2160p (4K):** Use **HEVC (H.265)** (`hevc_amf` / `hevc_vaapi` / `libx265`).
- **Master Playlist Specification Compliance:**
  - For 2160p, declare the canonical Apple HLS / CMAF HEVC codec tag:
    `CODECS="hvc1.1.6.L153.B0,mp4a.40.2"` (HEVC Main Profile, Main Tier, Level 5.1).
- **GPU Service Adaptation (`rust/src/services/gpu_service.rs`):**
  - Add `codec: VideoCodec` parameter to `get_ffmpeg_video_args(use_vpp_amf, target_height, codec)`.
  - When target is 2160p (or HEVC requested), emit `-c:v hevc_amf` (AMD AMF hardware HEVC encoder).
  - Both discrete AMD Radeon RX 560X (`dx11:1`) and integrated AMD Radeon Vega 8 (`dx11:0`) have been probed and verified to support `hevc_amf` natively.

### 2.2 Client: Smart 4K Direct Play Routing (`flutter_client/`)
- **Smart Quality Resolution (`player_media_resolver.dart`):**
  - When the user selects `2160p` (or when source height == 2160 and device supports Direct Play of the container/codec):
    - Automatically resolve to Direct Play (`/media/<filename>`) if the client and container support it natively.
    - This provides **instant playback** (zero waiting for transcode initialization), **zero server CPU/GPU load**, and **lossless 4K bitstream quality**.
- **Quality Selector Sheet Enhancement (`quality_selector_sheet.dart`):**
  - Group and clearly badge 4K Direct Play: "4K Ultra HD (Direct Play - Lossless)" vs "2160p (Transcode HLS)".
  - When `supportsDirectPlay` is active, selecting 4K defaults to direct streaming.

### 2.3 Cache Invalidation:
- Purge legacy H.264 2160p cache for *Ghost in the Cell* so the new HEVC 2160p tier or Direct Play serves cleanly.

---

## 3. Scope of Changes

### What Changes:
1. `rust/src/services/gpu_service.rs`:
   - Add support for HEVC encoding (`hevc_amf`, `hevc_vaapi`, `libx265`).
   - Allow selecting video codec per target resolution tier.
2. `rust/src/services/hls_service.rs`:
   - Update `STANDARD_QUALITIES` codec string for `2160p` to `hvc1.1.6.L153.B0,mp4a.40.2`.
3. `rust/src/transcode/engine.rs` & `rust/src/transcode/planner.rs` & `rust/src/services/transcode_worker.rs`:
   - Pass video codec selection into FFmpeg chunk transcode arguments based on target resolution (HEVC for 2160p, H.264 for <= 1440p).
4. `flutter_client/lib/features/player/infrastructure/player_media_resolver.dart`:
   - Enhance `resolveQualityUrl`: map 2160p to Direct Play when source is native 2160p and `directPlay` is supported.
5. `flutter_client/lib/features/player/presentation/widgets/quality_selector_sheet.dart`:
   - Polish 4K quality option labeling and badge display.

### What Deliberately Does NOT Change:
- Zero changes to <= 1440p HLS pipelines (1440p, 1080p, 720p, 480p, 360p remain 100% untouched and H.264).
- Zero changes to `/api/*` endpoint contracts or response shapes.
- Zero changes to subtitle synchronization, audio stream selection, or seek preview thumbnail extraction.

---

## 4. Exit Criteria

1. **Host GPU Verification:**
   - Both AMD GPUs (`dx11:0` Vega 8 and `dx11:1` RX 560X) successfully encode 4K test chunks using `hevc_amf`.
2. **Backend Compilation & Test Suite:**
   - `cargo test` in `rust/` passes with 0 failures.
   - `cargo build --release` compiles cleanly without warnings or errors.
3. **Android API Contract Probe:**
   - `python scripts/probe_android_api.py` passes 22/22 endpoints with HTTP 200.
4. **Android Client Verification on Connected Device (`192.168.1.6:40283`):**
   - *Ghost in the Cell* streams 4K smoothly without buffering stalls or frame drops.
   - Selecting 1440p, 1080p, 720p continues to stream smoothly via H.264 HLS without regression.
   - Live logcat confirms hardware acceleration (`c2.qti.hevc.decoder`) without MediaCodec errors.

---

## 5. Risks & Mitigation

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Old Web Browsers Lacking HEVC** | Desktop Chrome without HEVC hardware/extension cannot decode HEVC fMP4. | Only 2160p uses HEVC. Web clients auto-select 1440p or 1080p H.264 HLS, or use Direct Play if browser supports it. |
| **fMP4 Ingestion in Dual-GPU Pipeline** | `hevc_amf` chunk initialization atoms (`init_chunk_X.mp4`) must be valid CMAF. | Pre-validated with FFmpeg test run: `+cmaf+separate_moof+delay_moov+skip_trailer` produces valid `hvc1` initialization fragments. |
| **Cross-Client Direct Play Mismatch** | A client might advertise direct play support but lack HEVC codec. | `direct_play` is determined per-client from `/api/media-info/<filename>?client=android` where Android's HEVC support is explicitly validated. |

---

## 6. Open Decisions for User

1. **Quality Sheet 4K Behavior on Direct Play Capable Devices:**
   - **Option A (Recommended):** When the source is 4K and the client supports Direct Play, selecting "4K" routes directly to Direct Play (`/media/...`) for lossless quality, zero server GPU load, and instant startup; if forced to HLS, serves 4K HEVC.
   - **Option B:** Always generate and serve 4K HEVC HLS transcode stream even when Direct Play is supported.
