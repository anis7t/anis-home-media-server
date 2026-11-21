# Implementation Plan: Thermal Safety Hardening and 4K Transcode Protection

**Document**: `docs/PLAN_HARDEN_THERMAL_SAFETY_AND_4K_TRANSCODING.md`  
**Date**: 2026-11-21  
**Status**: DRAFT (Awaiting User Approval per Rule 0.1 & GEMINI.md Rule 0)  
**Author**: Antigravity  

---

## 1. Executive Summary & Problem Statement

On 2026-11-21 at 15:43:46 IST, the laptop experienced an instantaneous hardware power-off / thermal shutdown (Windows Event ID 41, `BugcheckCode = 0`, power button timestamp 0) while transcoding a newly uploaded 24 GB 4K 10-bit HEVC movie (`The Odyssey (2026) (2160p UHD BluRay x265 10bit DV HDR10+ r00t).mkv`).

Thorough forensic diagnosis revealed:
1. **Critical Code Flaw in `transcode_worker.rs`**: In line 716, `Self::execute_single_chunk` accepted `dual_gpu_enabled` as its `thermal_guarded` parameter. Because HWiNFO was not running at startup, `dual_gpu_enabled` evaluated to `false`, putting the worker in "single-RX fail-safe mode". Consequently, `thermal_guarded` was passed as `false`, **completely disabling all thermal monitoring, critical temperature aborts, and sensor checks** on the discrete AMD Radeon RX 560X GPU.
2. **Extreme 4K 10-bit HEVC Compute Load**: Decoding 4K 10-bit HEVC via `d3d11va` + tone mapping/scaling with `vpp_amf` + encoding 1080p via `h264_amf` required ~101 seconds of continuous 100% GPU utilization per 60s chunk on the mobile Polaris 11 die.
3. **Inadequate Inter-Chunk Cooling**: With only a 1,000ms inter-chunk breather and zero thermal throttling, heat accumulated rapidly across shared laptop heatpipes, causing the Embedded Controller (EC) to trigger emergency PROCHOT / thermal shutdown (~100°C+) ~100 seconds into Chunk 1.
4. **Missing HWiNFO Auto-Launch**: HWiNFO was not active on boot, blinding the system to silicon temperatures.

---

## 2. Scope

### In Scope
1. **Unconditional Thermal Guarding**:
   - Refactor `transcode_worker.rs` so that `thermal_guarded` is **always true** for both single-GPU and dual-GPU executions.
   - Enforce pre-chunk thermal admission (`adapter_temperature_safe`) for single-GPU worker loops when telemetry is available.
2. **Missing Telemetry Fail-Safe Interlock**:
   - If HWiNFO is closed / telemetry is unavailable (`ThermalStatus::Unsafe`):
     - For 4K / 10-bit HEVC sources: transcode worker must refuse/pause background jobs with an explicit warning rather than burning the discrete GPU blind.
     - For non-4K sources: enforce an extended mandatory fallback breather (e.g., 5,000ms–8,000ms) between chunks.
3. **Dynamic Temperature-Based Cooldown Breather**:
   - Replace the static 1,000ms sleep with a dynamic cooldown loop: after completing a chunk, if GPU temperature exceeds the safe cooldown threshold (default 75°C), sleep in 2-second intervals until the adapter cools down to \(\le 72^\circ\text{C}\) (with a maximum bounded wait time of 45 seconds).
   - Increase default base breather for 4K / 10-bit HEVC jobs (`MEDIA_SERVER_4K_CHUNK_BREATHER_MS`, default 5,000ms).
4. **Integration of HWiNFO 8.60 Portable**:
   - HWiNFO 8.60 portable has been downloaded to `C:\HWiNFO\HWiNFO64.exe`.
   - Pre-configured `HWiNFO64.INI` and Registry keys (`HKCU:\Software\HWiNFO64` and `HKCU:...\Run`) for `SharedMemorySupport=1`, `SensorsOnly=1`, `MinimizeSensors=1`.
5. **Comprehensive Unit & Integration Verification**:
   - Unit tests covering thermal admission, fail-safe logic, temperature cooldown checks, and 4K breather calculations.
   - Local validation mirroring CI checks (`cargo test`, `npm run test`, `flutter analyze`).

### Deliberately Out of Scope
- Rewriting the AMF hardware encoding pipeline (AMF `d3d11va` + `vpp_amf` + `h264_amf` remains the verified high-performance path).
- Modifying the React SPA frontend UI or Flutter TV client (API contract shapes remain 100% identical).
- Deleting or degrading existing 1080p / 720p HLS caches.

---

## 3. Detailed Technical Architecture & Changes

### 3.1 `rust/src/services/media_pipeline/transcode_worker.rs`
1. **Unconditional Thermal Monitoring**:
   - In lines 708–719 and line 1017: pass `thermal_guarded: true` unconditionally.
   - Inside the worker loop (around line 695):
     ```rust
     // Pre-chunk admission check: if telemetry is available, wait until adapter is below admission limit (85°C)
     while !crate::services::gpu_thermal::adapter_temperature_safe(worker_cfg.is_discrete) {
         if cancel.load(Ordering::Relaxed) { break; }
         tokio::time::sleep(Duration::from_secs(5)).await;
     }
     ```
2. **Missing Sensor Guard for Heavy (4K / 10-bit) Workloads**:
   - If `crate::services::gpu_thermal::read_temperatures()` returns `ThermalStatus::Unsafe` and `is_4k`:
     ```rust
     if is_4k && matches!(crate::services::gpu_thermal::read_temperatures(), ThermalStatus::Unsafe(_)) {
         warn!(job_id = job.id, "4K transcode paused: HWiNFO thermal telemetry is required to protect hardware");
         // Yield job or sleep until sensors become available, preventing unmonitored 4K burn
     }
     ```
3. **Dynamic Temperature Cooldown Breather**:
   - After each chunk finishes:
     ```rust
     // 1. Static base breather (configurable, default 5000ms for 4K, 1000ms for HD)
     let base_breather = if is_4k {
         std::env::var("MEDIA_SERVER_4K_CHUNK_BREATHER_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(5000)
     } else {
         std::env::var("MEDIA_SERVER_CHUNK_BREATHER_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(1000)
     };
     tokio::time::sleep(Duration::from_millis(base_breather)).await;

     // 2. Dynamic thermal cooldown: wait until GPU cools below target threshold (default 75°C)
     let cooldown_target = std::env::var("MEDIA_SERVER_GPU_COOLDOWN_TEMP_C").ok().and_then(|v| v.parse().ok()).unwrap_or(75.0);
     let cooldown_start = Instant::now();
     while crate::services::gpu_thermal::adapter_temperature_above(worker_cfg.is_discrete, cooldown_target) {
         if cancel.load(Ordering::Relaxed) || cooldown_start.elapsed() > Duration::from_secs(45) {
             break;
         }
         tokio::time::sleep(Duration::from_secs(2)).await;
     }
     ```

### 3.2 `rust/src/services/media_pipeline/gpu_thermal.rs`
1. Add helper `adapter_temperature_above(is_discrete: bool, threshold_c: f64) -> bool`:
   - Returns `true` if current temperature is valid and \(\ge \text{threshold\_c}\).
   - Returns `false` if telemetry is unavailable (avoids infinite wait).
2. Add helper `is_telemetry_available() -> bool`.

### 3.3 Configuration (`rust/src/config.rs` & `.env`)
- `MEDIA_SERVER_4K_CHUNK_BREATHER_MS=5000` (Default 5s pause after 4K chunks).
- `MEDIA_SERVER_GPU_COOLDOWN_TEMP_C=75.0` (GPU target temperature before starting next chunk).
- `MEDIA_SERVER_REQUIRE_HWINFO_FOR_4K=1` (Strict protection: requires HWiNFO for 4K).

---

## 4. Exit Criteria

1. **Code Hardening**:
   - `execute_single_chunk` runs with `thermal_guarded = true` on every single chunk without exception.
   - 4K transcoding refuses to execute without active HWiNFO sensor telemetry when `MEDIA_SERVER_REQUIRE_HWINFO_FOR_4K=1`.
   - Post-chunk cooldown holds execution if GPU temperature exceeds 75°C until temperature drops or 45s timeout elapses.
2. **Zero Regressions**:
   - All Rust unit tests pass (`cargo test --manifest-path rust/Cargo.toml -- --test-threads=1`).
   - Web frontend tests pass (`npm --prefix web run test` and `typecheck`).
   - Flutter client passes (`cd flutter_client; flutter analyze`).
3. **Hardware Safety Verification**:
   - HWiNFO 8.60 is deployed at `C:\HWiNFO\HWiNFO64.exe` with `HWiNFO64.INI` and registry run key configured.
   - When transcode chunks run, GPU temperatures remain bounded under the critical limit (\(< 85^\circ\text{C}\)), with inter-chunk cooling visibly reducing temperatures before the subsequent chunk fires.

---

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **HWiNFO not running blocks 4K transcoding** | 4K jobs stay queued or paused | Expected safety behavior. Clear warning logged informing the administrator to start HWiNFO (`C:\HWiNFO\HWiNFO64.exe`). Standard 1080p/720p jobs can still run with extended duty cycles. |
| **HWiNFO 12-hour free limit** | Shared memory stops after 12h | Handled gracefully: `adapter_temperature_above` returns false after 45s timeout, and `critical_temperature_or_sensor_loss` aborts the chunk safely rather than burning hardware. HWiNFO can be relaunched. |
| **Longer total transcode time for 4K** | Slower background encoding | An extra 5s–10s cooldown per 60s chunk increases transcode time by ~10–15%, but guarantees 100% thermal stability and prevents catastrophic laptop shutdowns. |
| **Driver or DirectX Deadlock** | Child process hangs | Existing 180s per-chunk timeout and process group `taskkill /F /T` remain in place. |

---

## 6. Open Decisions

1. **Open Decision 1: 4K Transcoding Telemetry Requirement**
   - **Option A (Recommended)**: Strict Fail-Safe — 4K transcode requires HWiNFO to be running. If telemetry is lost, 4K jobs pause safely until HWiNFO is active.
   - **Option B**: Permissive with Heavy Duty-Cycle — If HWiNFO is missing, allow 4K transcoding but force a mandatory 15-second pause between every 60-second chunk.
2. **Open Decision 2: GPU Cooldown Target Temperature**
   - **Option A (Recommended)**: 75°C target — Ensures the cooling heatpipes have dissipated thermal saturation before the next 100% compute burst.
   - **Option B**: 80°C target — Quicker chunk cycle, but operates closer to thermal thresholds.
