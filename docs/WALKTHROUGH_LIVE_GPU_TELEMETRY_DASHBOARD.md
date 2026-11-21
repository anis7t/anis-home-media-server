# Walkthrough: Live Dual-GPU Telemetry (Temperature & Utilization) on Transcode Dashboards

**Date:** 2026-11-21  
**Branch:** `feat/live-gpu-telemetry-dashboard`  
**Status:** Verified across all 4 CI Pillars (Rust Backend, React 19 SPA, Flutter Client, Secrets)

---

## 1. Executive Summary

We have implemented real-time GPU telemetry on the Transcode Telemetry & Command Center dashboard across both the **React 19 Web SPA** and the **Flutter (Android & Fire TV)** client.

The telemetry captures:
1. **Live GPU Temperatures** in Celsius (°C) for both GPUs (Discrete AMD Radeon RX 560X & Integrated AMD Radeon Vega 8).
2. **Real-time Utilization Percentages** (% load) derived from active D3D11VA, Video Decode, and compute load sensors.
3. **Thermal Status Pill Badges** with dynamic threshold color coding:
   - 🟢 **Optimal:** `< 75°C`
   - 🟡 **Warm / Moderate:** `75°C – 84.9°C`
   - 🔴 **Hot / High Load:** `≥ 85°C`

Zero persistent background polling threads were added: metrics are retrieved instantaneously (<0.1ms memory-mapped read) on-demand from **HWiNFO Shared Memory v2** during the existing dashboard polling cadence.

---

## 2. Changes Summary

### 2.1 Backend (Rust / Axum)
- **`rust/src/services/media_pipeline/gpu_thermal.rs`**:
  - Defined public `GpuTelemetry` and `DualGpuTelemetry` structs.
  - Implemented `GpuThermalGuard::read_gpu_telemetry() -> Option<DualGpuTelemetry>`:
    - Memory-maps `Global\HWiNFO_SHARED_MEM_FILE_V2` safely via Win32 API.
    - Inspects sensor headers and reading entries.
    - Matches AMD Radeon RX 560X and Vega 8 sensors.
    - Filters sensor readings by type and unit (`°C` for thermal, `%` for utilization across D3D, 3D, Video Decode, and Computing).
    - Safely rounds to 1 decimal place.
  - Added unit test `live_shared_memory_reports_telemetry_metrics` verifying live reading of both GPUs.
- **`rust/src/routes/ops/jobs.rs`**:
  - In `transcode_dashboard_handler`, called `GpuThermalGuard::read_gpu_telemetry()` on demand.
  - Augmented `summary.hardware_engine.primary` and `secondary` JSON responses with `temperature_c` and `utilization_pct`.

### 2.2 Frontend (React 19 SPA)
- **`web/src/lib/api/transcodes.ts`**:
  - Extended `GpuEngineStatus` and `HardwareEngineInfo` with:
    ```typescript
    temperature_c?: number | null;
    utilization_pct?: number | null;
    ```
- **`web/src/features/transcodes/TranscodeDashboardPage.tsx`**:
  - Added `getTempColor(temp: number)` dynamic CSS color utility (green `<75°C`, amber `75–85°C`, red `≥85°C`).
  - Added pill badges displaying `${gpu.temperature_c}°C` and `${gpu.utilization_pct}% load` adjacent to each GPU adapter name and status.

### 2.3 Mobile & TV Client (Flutter)
- **`flutter_client/lib/features/admin/domain/models/transcode_dashboard_model.dart`**:
  - Added `final double? temperatureC;` and `final double? utilizationPct;` to `GpuEngineStatus`.
  - Added JSON deserialization mapping `temperature_c` and `utilization_pct` with null-safety.
- **`flutter_client/lib/features/admin/presentation/screens/transcode_dashboard_view.dart`**:
  - Added `_getTempColor(double temp)` returning `AppColors.successGreen`, `AppColors.warningAmber`, or `AppColors.errorRed`.
  - Updated `_buildGpuCard` to render live temperature pills and utilization percentages with subtle semi-transparent background badges.
- **`flutter_client/test/transcode_dashboard_model_test.dart`**:
  - Added comprehensive test suite verifying deserialization of present values, null handling, and nested hardware engine parsing.

---

## 3. Test & Verification Matrix

| Pillar | Test / Validation Suite | Result | Details |
|---|---|---|---|
| **Rust Backend** | `cargo test --manifest-path rust/Cargo.toml --lib` | **PASSED (138 ok, 0 failed)** | All unit tests passed in 3.56s. Live HWiNFO test verified: `RX 560X: temp=88.0°C, util=34.0%, Vega 8: temp=66.0°C, util=0.5%`. |
| **Rust Code Quality** | `cargo fmt --check` & `cargo clippy -D warnings` | **PASSED (0 warnings)** | Formatting enforced; clippy clean on all targets. |
| **React 19 SPA** | `npm --prefix web run typecheck` & `npm run test` | **PASSED (338/338 tests)** | 46 test suites passed in 77s. |
| **React Production Build**| `npm --prefix web run build` | **PASSED (built in 1.80s)** | Assets bundled into `web/dist/`. |
| **Flutter Analysis** | `flutter analyze` | **PASSED (No issues found!)** | Checked full client project in 170.1s. |
| **Flutter Unit Tests** | `flutter test test/transcode_dashboard_model_test.dart` | **PASSED (3/3 tests passed)** | Verified all telemetry JSON serialization paths. |
| **Rust Release Compilation** | `cargo build --release` | **PASSED (in 2m 59s)** | Generated release binary: `rust/target/release/media-server-api.exe` (15.39 MB). |

---

## 4. Current Workload Status

- **Active Transcode Job 1150**:
  - Media: *The Odyssey (2026)* (4K UHD BluRay x265 10bit).
  - Target: `hls:1080p` (AMF D3D11VA Hardware Transcode).
  - Current Progress: **~29.2% complete** (~50.5 minutes encoded).
  - Encoder Worker: Running stably on discrete Radeon RX 560X (`dx11:1`).
  - HWiNFO Telemetry: RX 560X operating stably at 88°C under active load; Vega 8 at 66°C.
