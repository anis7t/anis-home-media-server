# Implementation Plan: Dual-GPU 4K Transcoding with Thermal Safeguards & Rollback

**Date:** 2026-11-21  
**Target:** Media Server Rust Backend (`rust/src/services/media_pipeline/`)  
**Status:** DRAFT (Awaiting User Approval)

---

## 1. Executive Summary & Objective

Enable concurrent dual-GPU chunked transcoding across both physical GPUs:
- **Discrete GPU:** AMD Radeon RX 560X (`dx11:1`, dedicated 4 GB GDDR5 VRAM)
- **Integrated GPU:** AMD Radeon Vega 8 (`dx11:0`, shared system DDR4 memory)

for heavy and 4K UHD workloads (e.g. *The Odyssey* 2160p), while strictly enforcing thermal safety limits, per-adapter cooldown gates, and providing an instant zero-downtime rollback mechanism.

---

## 2. Scope of Changes

### What Changes:
1. **Intra-Job Dual-GPU Worker Expansion (`rust/src/services/media_pipeline/transcode_worker.rs`)**:
   - Lift the hardcoded `is_4k` single-GPU clamp in `TranscodeWorker::execute_job` (which previously forced `workers = vec![discrete_gpu]` whenever `height >= 1800` or quality was `2160p`).
   - Allow the worker pool to retain both physical adapters (`[Radeon RX 560X, Radeon Vega 8]`) for 4K workloads when dual-GPU is enabled (`MEDIA_SERVER_ENABLE_DUAL_GPU=1`).
   - Add a dedicated feature flag `MEDIA_SERVER_4K_DUAL_GPU` (defaulting to enabled when `MEDIA_SERVER_ENABLE_DUAL_GPU=1`) so dual-GPU 4K transcoding can be toggled on or off via `.env` without code changes.

2. **Per-Adapter Thermal Admission & Dynamic Cooldown**:
   - Leverage the existing per-worker thermal loops:
     - Worker 0 (RX 560X): monitors discrete GPU temperature (`adapter_temperature_safe(true)`).
     - Worker 1 (Vega 8): monitors integrated GPU temperature (`adapter_temperature_safe(false)`).
   - If either GPU approaches the 85.0°C admission limit, that specific GPU thread pauses and waits for its adapter to cool below `MEDIA_SERVER_GPU_COOLDOWN_TEMP_C` (75.0°C) without blocking or stalling the other GPU.
   - Active chunk watchdog: if either GPU hits the critical threshold (92.0°C), its active FFmpeg process is immediately terminated via `[THERMAL_PAUSE]`.

3. **Rollback Architecture**:
   - **Binary Backup:** Create an immutable backup of the current production release binary:
     `E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe.bak-single-gpu`
   - **Configuration Toggle:** Setting `MEDIA_SERVER_4K_DUAL_GPU=0` in `E:\MediaServer\.env` immediately restores single-GPU 4K execution upon service reload without needing to recompile.
   - **1-Command Rollback Script:** Provide a PowerShell rollback script (`scripts/rollback_single_gpu_transcode.ps1`) to instantly swap back the previous binary and restart `MediaServerRust`.

### What Deliberately Does Not Change:
- Existing 720p/1080p single-job priority and quality ladders.
- The 4K AMF filter chain (`vpp_amf` with `setparams=color_primaries=bt709...` which enables both GPUs to encode HEVC without hanging).
- The Flutter Android / Fire TV client code (no client updates required).

---

## 3. Exit Criteria

1. **Dual-GPU Chunk Execution**:
   - `logs\rust_api.log` confirms that both `adapter_id=0` (Vega 8) and `adapter_id=1` (RX 560X) are actively spawned and encoding chunks concurrently for Job 1148 (*The Odyssey* 2160p).
   - Task Manager / Windows Performance counters show active video decode/encode utilization on **both** GPU 0 (Vega 8) and GPU 1 (RX 560X).
2. **Thermal Safeguards Verified**:
   - HWiNFO Shared Memory telemetry continues to poll both temperatures every 1.5 seconds.
   - Neither adapter exceeds the critical safety threshold (92.0°C).
   - If an adapter hits $\ge 85^\circ\text{C}$, only that adapter pauses for cooldown while the cooler adapter continues.
3. **Stream Playback Continuity**:
   - The generated HLS fMP4 segments from both GPUs are validated via master playlist assembly (`update_master_playlist`).
   - Timeline synchronization (`-output_ts_offset`) ensures zero PTS drift across mixed-GPU chunks.
4. **Rollback Tested**:
   - Binary backup verified on disk.
   - Configuration toggle verified.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation Strategy |
| :--- | :--- | :--- |
| **Combined Thermal Saturation** | Both GPUs heating up together on the shared laptop cooling pipes | The existing inter-chunk breather (5000ms) + dynamic cooldown target (75°C) + critical 92°C hardkill ensure the laptop package never overheats. |
| **Vega 8 Unified Memory Bus Pressure** | Vega 8 4K encoding contending for CPU RAM bandwidth | Vega 8 encodes at ~16 fps (lower memory bandwidth than RX 560X at 28 fps). If Vega 8 throttles or slows, the RX 560X continues processing chunks independently. |
| **AMF Driver Instability under Concurrent Load** | AMD driver crash or TDR event | Windows TDR delay is configured (`TdrDelay=60`), and each chunk worker runs in an isolated subprocess (`cmd.exe /c ffmpeg`). A failed chunk triggers clean retry/pause without killing the server. |
| **Need for Immediate Reversion** | User prefers single-GPU operation | Setting `MEDIA_SERVER_4K_DUAL_GPU=0` in `.env` or running `rollback_single_gpu_transcode.ps1` instantly reverts to single-GPU execution. |

---

## 5. Rollback Procedure

If dual-GPU 4K transcoding needs to be rolled back for any reason:

### Fast Path (Config Toggle - No recompilation needed):
1. In `E:\MediaServer\.env`, add or set:
   ```dotenv
   MEDIA_SERVER_4K_DUAL_GPU=0
   ```
2. Restart the service:
   ```powershell
   Restart-Service MediaServerRust
   ```
3. The server immediately reverts to running 4K transcoding on the discrete RX 560X alone.

### Complete Binary Rollback:
```powershell
Stop-Service MediaServerRust
Copy-Item "E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe.bak-single-gpu" "E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe" -Force
Start-Service MediaServerRust
```

---

## 6. Implementation Steps

1. **Step 1: Create Binary Backup & Rollback Script**:
   - Copy `media-server-api.exe` to `media-server-api.exe.bak-single-gpu`.
   - Write `scripts/rollback_single_gpu_transcode.ps1`.
2. **Step 2: Update Transcode Worker Logic**:
   - Modify `rust/src/services/media_pipeline/transcode_worker.rs`:
     - Introduce `MEDIA_SERVER_4K_DUAL_GPU` check.
     - Allow both discrete and integrated GPU workers to be provisioned for 4K jobs when dual-GPU is enabled.
3. **Step 3: Compile & Test**:
   - Run unit tests: `cargo test --manifest-path rust/Cargo.toml`.
   - Compile release binary: `cargo build --manifest-path rust/Cargo.toml --release`.
4. **Step 4: Deploy & Verify Live**:
   - Stop `MediaServerRust`.
   - Deploy new release binary.
   - Start `MediaServerRust`.
   - Observe live logs in `logs/rust_api.log` to confirm concurrent execution across both GPU adapters for Job 1148 (*The Odyssey*).
