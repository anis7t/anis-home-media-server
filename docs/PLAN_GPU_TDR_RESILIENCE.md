# Implementation Plan — Category 2: AMD GPU TDR Resilience (Issue 13)

- **Date:** 2026-10-24
- **Author:** Antigravity (Advanced Agentic Pair Programmer)
- **Status:** 📋 **PENDING USER APPROVAL**
- **Target Tracking:** Category 2 (Issue 13) in [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md), [`docs/Current issues.md`](Current%20issues.md)
- **Primary References:** [`docs/Current issues.md`](Current%20issues.md) §Issue 13, [`Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md`](../Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md), [`docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md`](TRANSCODE_CORRECTNESS_AND_TELEMETRY.md)

---

## 1. Context & Forensic Findings

Forensic analysis of the system restart logs and Windows Error Reporting (WER) queue revealed:
1. **The Core Hardware Failure:** The hybrid graphics subsystem (AMD Radeon RX 560X discrete `dx11:1` + AMD Radeon Vega 8 integrated `dx11:0`) experiences GPU Timeout Detection and Recovery (TDR) events (`0x00000117` and `0x00000141`) when under heavy compute stress.
2. **The AMF Correlation:** Transcode workers executing 3 concurrent chunk workers across both GPUs on 4K/HDR/Main10 content (`vpp_amf=true`, `workers=3`) correlated within 11–27 seconds to `LiveKernelReports` driver hang dumps.
3. **The OS Trigger:** Windows defaults to a tight **2-second** `TdrDelay`. When complex 4K HDR scenes or multiple concurrent AMF encoders saturate the D3D11 command queue, Windows prematurely resets the GPU driver before execution finishes, turning heavy encoding workloads into driver hangs or system resets.
4. **Current Concurrency:** `select_amf_strategy` in `gpu_service.rs` defaults to 3 workers for Main10/2160p content (2 on dGPU, 1 on iGPU), causing intra-GPU VRAM contention on the discrete RX 560X.

---

## 2. Scope

### In Scope
- **Windows Kernel TDR Configuration:**
  - Configure `TdrDelay = 8` (seconds) and `TdrDdiDelay = 20` (seconds) in `HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`. This provides sufficient headroom for intensive 4K chunk encodes without triggering false-positive driver resets.
- **Transcode Concurrency Calibration (`gpu_service.rs` & `.env`):**
  - Calibrate default `MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10` from 3 to 2 (1 worker dedicated per physical GPU: 1 on discrete RX 560X + 1 on integrated Vega 8), eliminating intra-adapter VRAM and PCIe bus contention.
  - Allow 8-bit lightweight encodes (1080p and below) to maintain high-throughput 2-worker parallel execution.
- **Chunk Execution Bounded Timeout & AMF Error Hardening (`transcode_worker.rs`):**
  - Add a per-chunk bounded timeout in `execute_single_chunk` (e.g. 180s) to prevent an unresponsive FFmpeg process from hanging the worker thread indefinitely.
  - Enhanced error pattern logging for AMF/D3D11 driver reset signatures (`AMF_FAIL`, `DXGI_ERROR_DEVICE_REMOVED`, `DEVICE_HUNG`).
- **Automated TDR Audit Utility (`scripts/audit_gpu_tdr.ps1`):**
  - Tool to inspect registry TDR parameters, active GPU driver versions, `LiveKernelReports`, and transcode concurrency settings.
- **2160p AMF Stress Acceptance Verification:**
  - Execute a multi-GPU 2160p AMF chunk transcode test and assert zero new dumps in `C:\Windows\LiveKernelReports`.

### Out of Scope
- Installing generic AMD Adrenalin drivers with DDU (high risk of black screen on laptop panel and misidentifying Vega 8 as Vega 11; current driver `31.0.21923.1000` is stable when concurrency is calibrated).
- Moving the HLS cache off `E:` (accepted invariant: stays on `E:`).
- Re-enabling a large pagefile (the 2 GB fixed reserved pagefile on `C:` is maintained).

---

## 3. Implementation Steps

### Step 1: Configure Windows Kernel TDR Parameters (`scripts/configure_tdr_registry.ps1`)
1. Create a script to inspect and set:
   ```powershell
   Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'TdrDelay' -Value 8 -Type DWord
   Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'TdrDdiDelay' -Value 20 -Type DWord
   ```
2. Verify registry properties are correctly populated.

### Step 2: Calibrate Heavy Profile Worker Concurrency (`rust/src/services/gpu_service.rs` & `.env`)
1. In `gpu_service.rs` `select_amf_strategy`:
   - Set default for `MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10` to `2` (1 per physical GPU: discrete + integrated), preventing dual-worker saturation on the single discrete GPU during 4K/HDR jobs.
2. In `.env`:
   - Set `MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10=2`
   - Set `MEDIA_SERVER_TRANSCODE_WORKERS_8BIT=2`

### Step 3: Implement Per-Chunk Bounded Timeout (`rust/src/services/transcode_worker.rs`)
1. In `execute_single_chunk`:
   - Wrap `child.wait_with_output()` in `tokio::time::timeout(Duration::from_secs(180), ...)`.
   - If timeout expires, terminate the child process (`taskkill /PID <pid> /F /T`) and return an explicit `AppError::Internal("Chunk execution timed out")`.
   - Log AMF-specific hardware failure diagnostic if stderr contains device reset strings.

### Step 4: Build Automated GPU Health & TDR Audit Tool (`scripts/audit_gpu_tdr.ps1`)
1. Create PowerShell tool that:
   - Audits `GraphicsDrivers` registry settings (`TdrDelay`, `TdrDdiDelay`).
   - Counts and inspects any `WATCHDOG` or `AMD_REPORT_UM` dumps in `C:\Windows\LiveKernelReports`.
   - Inspects `System` event log for `Kernel-Power 41` or display driver resets (Event 4101).
   - Validates AMF encoding via `ffmpeg -c:v h264_amf`.

### Step 5: Execute Acceptance Verification
1. Run `cargo test` in `rust/` to verify all unit/integration tests pass.
2. Run `scripts/audit_gpu_tdr.ps1` before testing (baseline dump count).
3. Execute a 2160p AMF chunk transcode job.
4. Verify:
   - Chunk completes successfully.
   - `C:\Windows\LiveKernelReports` dump count does NOT increase (zero new TDRs).
   - `rust_api.log` shows no worker failures.
5. Deliver walkthrough document `docs/WALKTHROUGH_GPU_TDR_RESILIENCE.md`.

---

## 4. Exit Criteria

- [ ] Registry `TdrDelay` set to 8 and `TdrDdiDelay` set to 20 in `GraphicsDrivers`.
- [ ] Concurrency for 4K/Main10 calibrated to 2 workers (1 discrete + 1 integrated), avoiding intra-GPU overloading.
- [ ] Per-chunk execution bounded with 180s timeout preventing unmonitored thread hangs.
- [ ] Automated audit tool `scripts/audit_gpu_tdr.ps1` passes all health checks.
- [ ] Acceptance test: 2160p AMF transcode runs without generating new `LiveKernelReports` dumps or worker errors.
- [ ] Rust and web test suites pass cleanly.

---

## 5. Risks & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Registry modification | OS level change | Only standard Microsoft-supported `GraphicsDrivers` keys (`TdrDelay`, `TdrDdiDelay`) are set; no driver binary or inf tampering. |
| Concurrency reduction for 4K | Slightly lower aggregate fps on 4K files | 2 workers across dual GPUs (1 discrete + 1 integrated) eliminates TDR thrashing and yields higher net throughput because jobs don't crash and retry. |
| Chunk timeout too short | Long slow chunks aborted prematurely | Target chunk duration is 10s; 180s timeout allows encoding as slow as 0.05x realtime before aborting. |

---

## 6. Open Decisions for User

1. **Registry TDR Value Application:**
   - **Option A (Recommended):** Apply `TdrDelay = 8` and `TdrDdiDelay = 20` via elevated PowerShell script now. (Takes effect immediately for new DirectX device contexts, fully persistent across boots).
   - **Option B:** Only calibrate concurrency in Rust without touching Windows registry.

2. **4K Concurrency Calibration:**
   - **Option A (Recommended):** Set `MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10 = 2` (1 worker on RX 560X + 1 worker on Vega 8).
   - **Option B:** Keep default at 3 workers and rely solely on registry TdrDelay relaxation.
