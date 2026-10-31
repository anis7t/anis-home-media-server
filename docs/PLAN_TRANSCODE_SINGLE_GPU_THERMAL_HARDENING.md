# Implementation Plan — Transcode Single-GPU Hardening & Thermal Pacing

**Document:** `docs/PLAN_TRANSCODE_SINGLE_GPU_THERMAL_HARDENING.md`  
**Date:** 2026-10-31  
**Author:** Antigravity  
**Target Host:** Acer Nitro AN515-43 (AMD Ryzen 5 3550H APU + AMD Radeon RX 560X dGPU)  
**Status:** Pending User Approval  

---

## 1. Executive Summary & Problem Context

On October 31, 2026, the media server host experienced three sudden hard power-loss shutdowns (`BugcheckCode = 0`, Kernel-Power Event ID 41):
1. **Crash 1:** ~20:39:28 IST (during 720p rung with `vpp_amf` scaling)
2. **Crash 2:** ~21:59:54 IST (during 480p rung, leaving chunks 18–20 incomplete)
3. **Crash 3:** ~22:45:57 IST (immediately upon Job #1135 completing and re-claiming Job #1134)

### The Root Cause
The previous stability fix implemented on October 24, 2026 for 4K HEVC (*Ghost in the Cell*) dedicated 4K jobs to a single discrete GPU to eliminate memory bus and driver contention. However, that fix was restricted strictly to `target_height >= 2160`.

For 1080p, 720p, 480p, and 360p, the engine continued to launch 2 parallel workers across both the integrated AMD Radeon Vega 8 (`dx11:0`) and discrete Radeon RX 560X (`dx11:1`). Lower resolutions with `vpp_amf` downscaling encode at extreme frame rates (>150–200 FPS each, >300 aggregate FPS). On the Acer Nitro 5 laptop chassis:
- The APU die (CPU + Vega 8) and dGPU die (RX 560X) share a single copper heatpipe bridge and a 135W power adapter.
- Sustained dual-GPU load over 60+ minutes causes thermal saturation.
- When APU junction temperature exceeds 105°C, AMD hardware asserts `THERMTRIP#`, cutting motherboard VRM power instantly without software warning or BSOD dump.
- Continuous back-to-back chunk execution with 0ms delay prevents the cooling assembly from dissipating heat.

---

## 2. Scope

### What Changes:
1. **Environment Configuration (`E:\MediaServer\.env`):**
   - Explicitly disable dual-GPU transcode concurrency (`MEDIA_SERVER_ENABLE_DUAL_GPU=0`).
   - Pin all transcode worker ladder variables to 1 worker (`MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10=1`, `MEDIA_SERVER_TRANSCODE_WORKERS_8BIT=1`, `MEDIA_SERVER_TRANSCODE_WORKERS_4K=1`).
   - Define a configurable inter-chunk thermal breather (`MEDIA_SERVER_CHUNK_BREATHER_MS=500`).
2. **GPU Worker & Strategy Engine (`rust/src/services/media_pipeline/gpu_service.rs`):**
   - Update `is_dual_gpu_enabled()` to default to `false` when not explicitly set, enforcing single-GPU safety across mobile/APU hosts.
   - Update `select_amf_strategy` to check `is_dual_gpu_enabled()`. When disabled, force worker count to 1 for all resolution tiers.
   - Update `expand_workers`: when worker count is 1, guarantee selection of the primary discrete GPU (`is_discrete`, Radeon RX 560X) to bypass the integrated Vega 8 completely.
3. **Transcode Execution Loop (`rust/src/services/media_pipeline/transcode_worker.rs`):**
   - Enforce single discrete GPU worker constraint across **all** resolution tiers (4K, 1440p, 1080p, 720p, 480p, 360p) when dual-GPU is disabled.
   - Insert an asynchronous thermal breather (`tokio::time::sleep(Duration::from_millis(breather_ms)).await`) between chunks in the worker loop to allow silicon junction and VRM stage cool-down.
   - Configure Windows subprocess creation flag `0x00004000` (`BELOW_NORMAL_PRIORITY_CLASS`) for FFmpeg chunk workers to prevent background transcoding from starving Windows DWM or the Axum server.
4. **Database Queue Recovery (`transcode_jobs`):**
   - Reset Job #1134 (*Verity 2026* 480p) from `failed` to `queued` with `attempts = 0` so the engine can cleanly finish the remaining chunks under the stabilized pipeline.

### What Deliberately Does NOT Change:
- Direct Play RFC 7233 byte-range streaming (`/media/*`) and native media routing are unchanged.
- Fragmented MP4 (fMP4) packaging, segment duration stride (32 segments per chunk), and playlist assembly logic are preserved.
- Subtitle synchronization, TMDb scanning, authentication, and client contracts remain 100% identical.

---

## 3. Exit Criteria

The fix will be deemed successful and complete when all of the following criteria are verified:
1. **Compilation:** `cargo build --manifest-path rust/Cargo.toml --release` builds cleanly with zero warnings or errors.
2. **Unit Tests:** `cargo test --manifest-path rust/Cargo.toml -- --test-threads=1` passes all test cases.
3. **Service Deployment:** Updated binary is deployed to Windows Service `MediaServerRust` and starts cleanly.
4. **Client Contract Parity:** `python scripts/probe_android_api.py` passes 22/22 endpoints.
5. **Single-GPU Transcode Execution:** Verity 480p (Job #1134) executes exclusively on the discrete AMD Radeon RX 560X (`dx11:1`), logging single GPU dedication.
6. **Thermal & System Stability:** The full transcode run completes (100% progress, master playlist published with `#EXT-X-ENDLIST`) with zero system crashes, zero Kernel-Power Event 41 occurrences, and stable operating temperatures.

---

## 4. Risks & Mitigations

| Risk | Severity | Mitigation Strategy |
|---|---|---|
| **Transcoding Throughput Drop** | Low | The RX 560X alone provides 5.5x–7.0x realtime speed. Dropping Vega 8 only reduces aggregate speed by ~15-20% while cutting total thermal dissipation by ~45W. A 2-hour movie takes ~18 minutes instead of ~15 minutes. |
| **Incomplete Chunks in Cache** | Low | Chunks 18, 19, and 20 manifests were already purged. `ChunkTranscodeService::chunk_output_ok()` will detect their absence and regenerate them cleanly. |
| **Windows API Portability** | Low | Guard Windows-specific process priority flags (`creation_flags(0x00004000)`) with `#[cfg(windows)]` to preserve cross-platform build compatibility. |
| **Subsequent Sweeper Re-Queuing** | Low | The sweeper circuit breaker (`attempts < 3`) remains active as a safety net against any unexpected hardware stalls. |

---

## 5. Open Decisions

1. **Inter-Chunk Breather Duration:**
   - **Option A: 500 ms** — Adds only ~60 seconds total over a 120-chunk (2-hour) movie.
   - **Option B (Selected & Approved): 1000 ms** — Extra conservative thermal pacing; adds ~120 seconds total over a 2-hour movie while ensuring VRM stages and APU heatpipes fully stabilize between encoding bursts. Configured via `MEDIA_SERVER_CHUNK_BREATHER_MS=1000`.
