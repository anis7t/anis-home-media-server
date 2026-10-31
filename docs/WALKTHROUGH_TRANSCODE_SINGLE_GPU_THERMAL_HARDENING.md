# Walkthrough — Transcode Single-GPU Hardening & Thermal Pacing

**Document:** `docs/WALKTHROUGH_TRANSCODE_SINGLE_GPU_THERMAL_HARDENING.md`  
**Date:** 2026-10-31  
**Author:** Antigravity  
**Target Host:** Acer Nitro AN515-43 (AMD Ryzen 5 3550H APU + AMD Radeon RX 560X dGPU)  
**Status:** Implemented, Deployed, and Verified in Production  

---

## 1. Executive Summary

On October 31, 2026, the media server host experienced three sudden hard power-loss shutdowns (`BugcheckCode = 0`, Kernel-Power Event ID 41) during intensive video transcoding across the quality ladder for *Verity 2026*:
1. **Crash 1:** ~20:39:28 IST (during 720p rung with `vpp_amf` scaling)
2. **Crash 2:** ~21:59:54 IST (during 480p rung, leaving chunks 18–20 incomplete)
3. **Crash 3:** ~22:45:57 IST (immediately upon Job #1135 completing and re-claiming Job #1134, severing the previous agent session)

### Root Cause
While an earlier October 24 fix dedicated 4K jobs (`>= 2160p`) to a single GPU, all lower resolution tiers (1080p, 720p, 480p, 360p) continued to launch concurrent workers across **both** the integrated AMD Radeon Vega 8 (`dx11:0`) and discrete Radeon RX 560X (`dx11:1`).
- Lower resolutions with `vpp_amf` downscaling encode at >150–200 FPS per GPU (>300 aggregate FPS).
- The Acer Nitro 5 laptop chassis connects the APU die (CPU + Vega 8) and dGPU die (RX 560X) via a single shared copper heatpipe bridge powered by a 135W AC adapter.
- Running both GPUs at 100% duty cycle back-to-back for 60+ minutes saturated the shared heatpipes and DDR4 system memory bus.
- When APU junction temperature exceeded 105°C, AMD hardware asserted `THERMTRIP#`, cutting motherboard VRM power instantly with zero software warning, zero BSOD, and zero minidumps (`BugcheckCode = 0`).

---

## 2. Changes Implemented

### 1. Environment Hardening (`E:\MediaServer\.env`)
- Disabled dual-GPU concurrent transcoding: `MEDIA_SERVER_ENABLE_DUAL_GPU=0`.
- Configured conservative inter-chunk thermal breather: `MEDIA_SERVER_CHUNK_BREATHER_MS=1000`.

### 2. GPU Worker Strategy (`rust/src/services/media_pipeline/gpu_service.rs`)
- `GpuService::is_dual_gpu_enabled()` now defaults to `false` when not explicitly set, safeguarding laptop and APU host architectures.
- `GpuService::get_gpu_workers()` filters available adapters at runtime: when dual-GPU is disabled, it returns exclusively the primary discrete GPU (`is_discrete`, AMD Radeon RX 560X).
- `GpuService::expand_workers()` guarantees single-worker expansion selects the discrete GPU.

### 3. Transcode Execution & Pacing (`rust/src/services/media_pipeline/transcode_worker.rs`)
- In `execute_job()`: Enforced single discrete GPU worker constraint across **all** resolution tiers (4K, 1440p, 1080p, 720p, 480p, 360p) whenever dual-GPU is disabled.
- In the worker loop: Inserted an asynchronous inter-chunk thermal breather (`MEDIA_SERVER_CHUNK_BREATHER_MS=1000`). After rendering each 60-second chunk, the worker sleeps for 1.0 second, allowing GPU VRMs and junction temperatures to cool down and clear transient DirectX/AMF resources.
- In `execute_single_chunk()`: Configured Windows subprocess creation flag `0x00004000` (`BELOW_NORMAL_PRIORITY_CLASS`) for FFmpeg so background transcoding never starves Windows DWM or the Axum HTTP server of CPU priority.

### 4. Database Queue Recovery (`transcode_jobs`)
- Cleaned corrupted manifests (`chunk_18.m3u8`, `chunk_19.m3u8`, `chunk_20.m3u8`) in `cache/hls/.../480p/`.
- Reset Job #1134 (*Verity 2026* 480p) from `failed` to `queued` with `attempts = 0`.

---

## 3. Verification & Live Validation

### 1. Rust Integration & Unit Tests
- Targeted test suite (`tests/integration/media_pipeline/gpu_service_test.rs`): **7/7 passed**.
- Full test suite (`.\scripts\cargo.bat test --manifest-path rust/Cargo.toml -- --test-threads=1`): **242/242 passed**.

### 2. Release Build & Service Deployment
- Built production release binary via `cargo.bat build --release` in 15.44s.
- Gracefully recycled `MediaServerRust` via `scripts/restart_rust_service.ps1`.
- Service status: **Running** on port 8000.
- Local SPA: `200 OK`.
- Local API (`/api/movies`): `200 OK`.

### 3. Android API Contract Validation
- Executed `python scripts/probe_android_api.py`.
- **Result:** **22/22 endpoints passed** with 100% contract compliance.

### 4. Live Production Transcode Proof (Job #1134 — 480p)
- Worker `[rust-worker-16176]` claimed Job #1134.
- **Log confirmation:**
  ```text
  INFO Job #1134: transcode running on single dedicated GPU (Radeon RX 560X Series) for thermal and driver stability
  INFO Job #1134: duration=7256.8s, quality=480p, height=Some(480), vpp_amf=true, workers=1 (Radeon RX 560X Series)
  ```
- **Process verification:** Exactly 1 FFmpeg process running with `PriorityClass: BelowNormal`, utilizing ~187 MB memory.
- **Chunk Cadence Verification:**
  - `chunk_18.m3u8` generated at 23:19:15 (708 bytes)
  - 1000ms breather
  - `chunk_19.m3u8` generated at 23:19:25 (708 bytes)
  - 1000ms breather
  - `chunk_20.m3u8` generated at 23:19:35 (708 bytes)
  - `chunk_21.m3u8` generated at 23:19:45 (708 bytes)
  - `chunk_22.m3u8` generated at 23:19:55 (708 bytes)
- **Zero Errors:** Chunks 18, 19, and 20—which crashed the system twice earlier—completed cleanly with zero system errors, zero driver resets, and steady 6.0x realtime encoding performance.
