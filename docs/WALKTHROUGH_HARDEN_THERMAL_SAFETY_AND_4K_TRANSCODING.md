# Walkthrough: Thermal Safety Hardening and 4K Transcode Protection

**Document**: `docs/WALKTHROUGH_HARDEN_THERMAL_SAFETY_AND_4K_TRANSCODING.md`  
**Date**: 2026-11-21  
**Status**: COMPLETED & VERIFIED  
**Branch**: `feat/thermal-safety-hardening`  

---

## 1. Overview & Root Cause Summary

Following a sudden laptop hardware power shutoff (Kernel-Power Event ID 41, `BugcheckCode = 0`, thermal trip) during high-load 4K HEVC transcoding, we performed a deep forensic diagnosis:
- **Trigger**: 24 GB 4K 10-bit HEVC movie (`The Odyssey (2026)`), pushing the mobile AMD Radeon RX 560X GPU to continuous 100% capacity for decoding (`d3d11va`), tone mapping/scaling (`vpp_amf`), and encoding (`h264_amf`).
- **Defect**: Single-GPU fallback mode passed `dual_gpu_enabled: false` into `execute_single_chunk` as the `thermal_guarded` parameter. Because HWiNFO was closed at system boot, `dual_gpu_enabled` evaluated to `false`, which completely **bypassed all thermal checks, critical temperature bounds (\(92^\circ\text{C}\)), and sensor monitoring**, running the discrete GPU completely blind until the embedded controller tripped emergency PROCHOT (~100°C+).
- **Cooling Deficit**: A fixed 1,000ms inter-chunk pause was insufficient to dissipate thermal saturation across the laptop's shared CPU/GPU heatpipes.

---

## 2. Key Deliverables & Changes

### 2.1 Unconditional Thermal Guarding on Every Chunk
- **File**: `rust/src/services/media_pipeline/transcode_worker.rs`
- **Change**: Refactored `execute_single_chunk` to pass `thermal_guarded: true` unconditionally.
- **Effect**: Single-GPU and dual-GPU executions now continuously poll thermal telemetry every 2 seconds. If temperature hits \(\ge 92^\circ\text{C}\) or sensor telemetry is lost, the worker immediately aborts the active FFmpeg child process via `taskkill /PID <pid> /F /T` and retains full diagnostic stderr logs.

### 2.2 Telemetry Admission & Missing-Sensor Interlock for Heavy/4K Workloads
- **Files**: `rust/src/services/media_pipeline/gpu_thermal.rs`, `rust/src/services/media_pipeline/transcode_worker.rs`
- **Change**: Added `gpu_thermal::is_telemetry_available()`, `adapter_temperature_above()`, and `get_adapter_temperature()`.
- **Protection**: If the job is heavy (4K source \(\ge 1800\text{p}\), 4K target \(\ge 1800\text{p}\), or 10-bit HEVC) and HWiNFO telemetry is unavailable, the transcode worker safely pauses the job with an explicit warning rather than allowing unmonitored compute loads to overheat the laptop.

### 2.3 Dynamic Post-Chunk Temperature Cooldown Loop
- **File**: `rust/src/services/media_pipeline/transcode_worker.rs`
- **Features**:
  - **Workload-Aware Base Breather**: 5,000ms default pause for 4K / heavy sources (`MEDIA_SERVER_4K_CHUNK_BREATHER_MS`), 1,000ms for standard HD.
  - **Dynamic Thermal Cooldown**: Before initiating the next chunk, workers poll the GPU adapter temperature. If the adapter is \(\ge 75^\circ\text{C}\) (`MEDIA_SERVER_GPU_COOLDOWN_TEMP_C`), the worker sleeps in 2-second increments until the adapter drops below \(75^\circ\text{C}\) (bounded by a 45-second timeout), ensuring the physical cooling solution dissipates heat before the next 100% burst.

### 2.4 HWiNFO 8.60 Portable Deployment
- **Location**: `C:\HWiNFO\HWiNFO64.exe`
- **Configuration**: `C:\HWiNFO\HWiNFO64.INI` created with `SharedMemorySupport=1`, `SensorsOnly=1`, `MinimizeSensors=1`.
- **Registry Integration**: Configured `HKCU:\Software\HWiNFO64` with `SharedMemorySupport=1`, `SensorsOnly=1`, and registered in `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run` for auto-start.

---

## 3. Verification & Test Outcomes

### 3.1 Rust Unit Tests & Integration Tests
- **Lib Unit Tests**:
  ```text
  cargo test --manifest-path rust/Cargo.toml --lib
  test result: ok. 138 passed; 0 failed; 2 ignored; 0 measured; 0 filtered out; finished in 2.07s
  ```
- **Media Info Integration Suite**:
  ```text
  cargo test --manifest-path rust/Cargo.toml --test integration media_pipeline::media_info_test
  test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 251 filtered out; finished in 2.98s
  ```
- **Static Analysis & Formatting**:
  ```text
  cargo fmt --manifest-path rust/Cargo.toml --check (Passed cleanly)
  cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings (Passed cleanly, 0 warnings)
  ```
- **Release Build Compilation**:
  ```text
  cargo build --release --manifest-path rust/Cargo.toml
  Finished `release` profile [optimized] target(s) in 1m 47s
  ```

### 3.2 Frontend & Client Parity Tests
- **React 19 SPA Unit Tests**:
  ```text
  npm --prefix web run test
  Test Files: 46 passed (46)
  Tests: 338 passed (338)
  ```
- **TypeScript Typecheck**:
  ```text
  npm --prefix web run typecheck
  tsc -b (0 errors)
  ```
- **Flutter TV / Mobile Client**:
  ```text
  cd flutter_client; flutter analyze
  No issues found! (ran in 154.7s)
  ```

---

## 4. Live Production Verification (Real 4K 10-Bit Transcode)

To conclusively verify that the thermal safety hardening works under extreme conditions:
1. **Live HWiNFO Telemetry Streaming**: HWiNFO 8.60 is running (PID 20076) and publishing sensor data via shared memory.
2. **Heavy Job Resumed**: Resumed Job 1150 (*The Odyssey (2026)* 24 GB 4K 10-bit HEVC) on the discrete AMD Radeon RX 560X.
3. **Active 2-Second Thermal Guard Verification**:
   - During Chunk 5, 6, and 7 encoding, the thermal monitor checked temperatures every 2 seconds against `critical_c=92.0`:
     ```text
     DEBUG Active GPU chunk thermal monitor check adapter="RX 560X" temperature_c=87.0 telemetry_age_secs=2 critical_c=92.0 stop=false
     ```
4. **Dynamic Cooldown Hold Verification**:
   - When Chunk 7 completed, the RX 560X reached 89°C.
   - The worker initiated the 5,000ms base breather and held the dynamic cooldown loop:
     - 12:19:58 UTC: `rx_temp_c = 89.0°C` -> held
     - 12:20:00 UTC: `rx_temp_c = 80.0°C` -> held
     - 12:20:02 UTC: `rx_temp_c = 70.0°C` (dropped below 75°C threshold!)
     - 12:20:02.788 UTC: `GPU chunk thermal admission check adapter="RX 560X" temperature_c=69.0 limit_c=85.0 admitted=true`
     - 12:20:02.807 UTC: Spawned Chunk 8 safely!
   - The physical cooling solution dropped GPU temperatures by 20°C (89°C -> 69°C) during the breather, completely preventing thermal saturation and thermal shutdown trips.

---

## 5. Summary & Operational Recommendations

- **Thermal Trip Prevented**: The root cause of the previous system crash (unmonitored single-GPU fallback running without thermal monitoring) has been eliminated.
- **Fail-Safe Operation**: If HWiNFO is ever closed or telemetry is lost, the server will refuse to start heavy 4K encodes, logging an explicit warning rather than allowing hardware damage or power trips.
- **Always Keep HWiNFO Running**: HWiNFO is configured in `HKCU\...\Run` to start minimized with sensors-only mode on user logon. A desktop shortcut is also available at `C:\Users\anis7\OneDrive\Desktop\HWiNFO64.lnk`.
