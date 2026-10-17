# Session Handoff — 2026-10-17 13:15 IST

**Author:** Antigravity (Gemini 3.8 Flash High)  
**Topic:** Real Movie Transcode Complete, 4K Hardware Encoding Analysis & Phase 8 Formulation  
**Branch:** `feat/rust-transcode-worker`  
**Governing Rules:** `AGENTS.md` §0.1, §0.2, §5; `GEMINI.md` §0, §1, §3  
**Status:** All tasks cleanly finalized, Phase 8 plan authored and verified, ready for new session.

---

## 1. What was completed in this session

1. **ActiveTranscodes vs HeroSpotlight Banner Collision Fixed (`web/`):**
   - Fixed the layout collision where active transcoding cards overlapped the library hero banner.
   - Updated [web/src/features/library/ActiveTranscodes.tsx](file:///e:/MediaServer/web/src/features/library/ActiveTranscodes.tsx) with `onActiveChange` callback and [web/src/features/library/HeroSpotlight.tsx](file:///e:/MediaServer/web/src/features/library/HeroSpotlight.tsx) with `hasTopBanner`.
   - Rebuilt production bundle via `npm run build` in `web/dist/`.

2. **Real Movie 4K Transcode Complete & Verified:**
   - Transcoded *Ghost in the Cell* (4K 2160p 10-bit HEVC, 17.9 Mbps, 106 minutes) to 1080p H.264 HLS via dual-GPU chunking (RX 560X + Vega 8).
   - Survived manual backend service restarts mid-stream without timeline drift or lost chunks.
   - Generated **1,593 HLS segments (2.77 GB)** with 106 chunk transitions (`#EXT-X-DISCONTINUITY`), **100.0% coverage (0 missing frames)**, and terminal `#EXT-X-ENDLIST` verified.

3. **4K HEVC & 4K H.264 Hardware Transcoding Investigation:**
   - **10-bit HEVC Driver Limitation**: Direct 10-bit HEVC hardware encoding fails on AMD AMF (`[hevc_amf] 10-bit encoder is not supported by AMD GPU drivers versions lower than 23.30`). Content requires format conversion to 8-bit NV12.
   - **4K 8-bit Performance Benchmarks on Real Hardware**:
     - *4K HEVC 8-bit*: RX 560X ~14.7 fps, Vega 8 ~17.1 fps (Dual-GPU aggregate: ~1.25x real-time).
     - *4K H.264 8-bit*: RX 560X ~21.8 fps, Vega 8 ~21.9 fps (Dual-GPU aggregate: ~1.82x real-time).
   - **Network Streaming Limits**:
     - *Local LAN / Wi-Fi*: **447.88 Mbps** measured throughput — easily streams 4K (18–35 Mbps) with 0 buffering.
     - *Remote Cloudflare Tunnel*: **18.43 Mbps** physical ISP upload ceiling — 4K streams saturate 100% of the uplink, causing permanent buffering. Remote viewing requires 1080p downscaling.

4. **Web Browser Compatibility & fMP4 Architecture:**
   - Identified that web browsers (Chrome/Firefox/Edge) fail to play HEVC inside legacy MPEG-TS (`.ts`) HLS streams.
   - Researched Netflix's architecture: Netflix uses Fragmented MP4 (`fMP4` / `.m4s`) / CMAF with native browser MSE demuxers, and restricts 4K to Edge (PlayReady) and Safari (FairPlay).
   - Confirmed that transitioning our media server to **fMP4 HLS (`.m4s`)** enables native hardware-accelerated playback in modern Chromium and Safari browsers.

5. **Phase 8 Implementation Plan Formulated & Saved:**
   - Authored [docs/PHASE_8_FMP4_QUALITY_LADDER_PLAN.md](file:///e:/MediaServer/docs/PHASE_8_FMP4_QUALITY_LADDER_PLAN.md).
   - Decided parameters:
     - Strategy: **Option A (On-Demand Single Stream)**.
     - Sequence: **Phase 8 executed now**, before Phase 7 (Port 8000 cutover).
     - Quality Tiers: Includes **2K (1440p)** alongside 4K, 1080p, 720p, 480p, 360p, and Direct.
     - Strict Invariant: **No upscaling** (a 1080p source never displays 2K/4K options).
     - Optimization: **MKV Direct Play for Android/Fire TV** (0% server GPU/CPU load).

---

## 2. Next Session Objective (Starting Phase 8)

Begin execution of **Phase 8: Fragmented MP4 (fMP4) Streaming, Dynamic Quality Ladder & Android Direct Play**:

* **Slice 1**: Update Rust GPU and transcode worker (`gpu_service.rs`, `transcode_worker.rs`, `chunk_transcode.rs`) for `-hls_segment_type fmp4` and target height scaling.
* **Slice 2**: Update Rust API contracts (`media_info.rs`, `hls.rs`) for dynamic quality ladder and Android MKV Direct Play.
* **Slice 3**: Implement In-Player Quality Selector in React Web Player (`PlayerControlsRow.tsx`, `PlayerPage.tsx`).
* **Slice 4**: Implement Android MKV Direct Play & TV Remote Quality Modal in Flutter client.

---

## 3. Paste-Ready Prompt for the New Session

```text
Please read the latest session handoff in Handoffs/2026-10-17_13-15_antigravity_phase-8-planning-and-transcode-complete.md and the approved implementation plan in docs/PHASE_8_FMP4_QUALITY_LADDER_PLAN.md.

I have already approved the Phase 8 plan (Option A, prior to Phase 7, 2K included, strict no-upscaling, fMP4 packaging, Android MKV Direct Play). Please proceed with implementing Slice 1: Rust fMP4 Transcode Engine & Quality Scaling.
```
