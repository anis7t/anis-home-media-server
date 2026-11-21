# Implementation Plan: Live GPU Temperature & Utilization in Transcode Admin Dashboard (React & Flutter)

**Document**: `docs/PLAN_LIVE_GPU_TELEMETRY_DASHBOARD.md`  
**Date**: 2026-11-21  
**Status**: DRAFT — AWAITING USER APPROVAL  

---

## 1. Executive Summary & Objective

The user requested displaying real-time **live temperature (in Celsius, °C)** and **utilization percentage (%)** for each GPU (Discrete AMD Radeon RX 560X and Integrated AMD Radeon Vega 8) in the Transcode Admin Dashboard across both client platforms:
1. **React 19 Web SPA** (`/transcodes` at `web/src/features/transcodes/TranscodeDashboardPage.tsx`)
2. **Flutter Android & Fire TV Client** (Transcode Dashboard View at `flutter_client/lib/features/admin/presentation/screens/transcode_dashboard_view.dart`)

The data will be polled live via HWiNFO Shared Memory v2 (which already streams temperature and utilization metrics) through the native Rust Axum backend endpoint `GET /api/transcode/dashboard`.

---

## 2. Scope & Architectural Boundaries

### In Scope:
1. **Rust Backend (`rust/src/services/media_pipeline/gpu_thermal.rs` & `rust/src/routes/ops/jobs.rs`)**:
   - Extend `gpu_thermal.rs` to extract both **Temperature (°C)** and **Utilization (%)** for discrete RX 560X and integrated Vega 8 from HWiNFO Shared Memory reading descriptors (HWiNFO reading types `1` = Temperature, `7` = Usage/Utilization).
   - Expose a unified telemetry struct `GpuTelemetrySummary { rx_temp_c: Option<f64>, rx_util_pct: Option<f64>, vega_temp_c: Option<f64>, vega_util_pct: Option<f64> }`.
   - Update `transcode_dashboard_handler` (`/api/transcode/dashboard`) to include `temperature_c` and `utilization_pct` in `summary.hardware_engine.primary` and `summary.hardware_engine.secondary`.
2. **React 19 Frontend (`web/src/features/transcodes/`)**:
   - Update TypeScript interfaces in `TranscodeDashboardPage.tsx` to include `temperature_c?: number` and `utilization_pct?: number` on `EngineStatus`.
   - Update the Hardware Engine telemetry card on `TranscodeDashboardPage.tsx` to render:
     - Temperature badge: e.g. `86°C` (color-coded: emerald `<75°C`, amber `75–85°C`, rose `>85°C`).
     - Utilization percentage: e.g. `45%` (or `0%` when idle).
3. **Flutter Client (`flutter_client/lib/features/admin/`)**:
   - Update `GpuEngineStatus` in `transcode_dashboard_model.dart` to parse `temperature_c` (as `double? temperatureC`) and `utilization_pct` (as `double? utilizationPct`).
   - Update `_buildGpuCard` in `transcode_dashboard_view.dart` to render real-time temperature (`XX°C`) and utilization (`XX%`) with adaptive color thresholds on both Android Mobile and Fire TV screens.
4. **Verification & Testing**:
   - Unit tests for telemetry parsing in Rust (`cargo test`).
   - React typecheck and unit tests (`npm run typecheck`, `npm run test`).
   - Flutter static analysis and tests (`flutter analyze`).
   - Live end-to-end verification via API and UI.

### Deliberately Out of Scope:
- Modifying transcode worker encoding logic, chunk durations, or HLS packaging.
- Altering existing transcode job queue schemas or database tables.
- Adding third-party telemetry agents outside of HWiNFO shared memory.

---

## 3. Exit Criteria

1. `GET /api/transcode/dashboard` returns `temperature_c` and `utilization_pct` fields for both `primary` (RX 560X) and `secondary` (Vega 8) engines when HWiNFO is active, returning `null` gracefully when telemetry is offline.
2. React Web dashboard (`/transcodes`) displays live temperature (in °C) and utilization (%) in the Hardware Engine card header for both GPUs.
3. Flutter Admin Transcode screen displays live temperature and utilization cards on Android and TV viewports.
4. All automated test suites across all three tiers pass with zero errors:
   - `cargo test --manifest-path rust/Cargo.toml --lib`
   - `npm --prefix web run test` && `npm --prefix web run typecheck`
   - `cd flutter_client; flutter analyze`

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **HWiNFO Shared Memory Closed / Inactive** | Telemetry unavailable | Default gracefully to `null` on backend; UI displays standard fallback `Standby` / `--` without throwing errors. |
| **Flutter / React Schema Drift** | Client crash on missing keys | Declare both `temperature_c` and `utilization_pct` as optional/nullable across TypeScript and Dart models with defensive fallback defaults. |
| **High Frequency UI Re-renders** | Dashboard DOM stutter | Leverage existing dashboard polling intervals (1–2s cadence) with zero additional network overhead. |

---

## 5. Open Decisions

1. **Color Coding Thresholds**:
   - Temperature: Green (`< 75°C`), Amber (`75°C – 85°C`), Red (`> 85°C`).
   - Utilization: Standard muted text when 0–5%, highlight brand color when actively encoding (> 10%).
   *(Recommended: Adopt standard thermal color thresholds aligned with transcode thermal safety bounds).*

---

## 6. Implementation Steps

### Step 1: Rust Backend Telemetry Parser
- In `rust/src/services/media_pipeline/gpu_thermal.rs`:
  - Add `read_gpu_telemetry() -> GpuTelemetryMetrics` parsing both `type == 1` (Temperature) and `type == 7` (Usage/Utilization `unit == '%'`) for RX 560X and Vega 8.
- In `rust/src/routes/ops/jobs.rs`:
  - Query `read_gpu_telemetry()` inside `transcode_dashboard_handler`.
  - Add `temperature_c` and `utilization_pct` to `summary.hardware_engine.primary` and `secondary`.

### Step 2: React Web Frontend (SPA)
- In `web/src/features/transcodes/TranscodeDashboardPage.tsx`:
  - Extend `EngineStatus` interface with optional `temperature_c?: number` and `utilization_pct?: number`.
  - Format metrics in the header card: e.g. `86°C · 42%` with dynamic thermal color badges.

### Step 3: Flutter Client (Android & Fire TV)
- In `flutter_client/lib/features/admin/domain/models/transcode_dashboard_model.dart`:
  - Add `temperatureC` and `utilizationPct` fields and JSON deserialization.
- In `flutter_client/lib/features/admin/presentation/screens/transcode_dashboard_view.dart`:
  - Render temperature pill and utilization indicator inside `_buildGpuCard`.

### Step 4: Verification
- Execute full test verification:
  - `cargo test --manifest-path rust/Cargo.toml --lib`
  - `npm --prefix web run test && npm --prefix web run typecheck`
  - `cd flutter_client; flutter analyze`
- Live service verification: check live endpoint and UI rendering.
