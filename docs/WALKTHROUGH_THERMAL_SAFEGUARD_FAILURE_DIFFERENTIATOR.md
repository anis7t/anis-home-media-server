# Walkthrough: Differentiating Generic Transcode Failures from Thermal Safeguard Pauses

**Date:** 2026-11-21  
**Branch:** `feat/thermal-safeguard-retry-differentiation`  
**Status:** Verified across all 4 CI Pillars (Rust Backend, React 19 SPA, Flutter Client, Secrets)

---

## 1. Executive Summary

We have decoupled **Thermal Safeguard Pauses** from **Generic Fatal Transcode Failures** across the transcoding engine, queue management, and admin dashboards (React SPA + Flutter Android & Fire TV).

### Key Architectural Improvements:
1. **Unlimited Retries for Thermal Safeguard Pauses**:
   - Physical cooling pauses and missing sensor telemetry conditions are recognized as temporary operational states rather than permanent media bitstream errors.
   - When a job is halted due to a critical thermal event ($\ge 92.0^\circ\text{C}$), the retry attempt counter is **not penalized** (`attempts` counter is restored/preserved).
2. **Circuit Breaker Exemption in Transcode Sweeper**:
   - `transcode_sweeper`'s 3-attempt circuit breaker (`attempts >= 3`) strictly guards against corrupt containers, missing streams, and broken codecs.
   - Thermal safeguard pauses are explicitly **exempt** from this breaker: jobs paused due to thermal protection are automatically and perpetually re-enqueued once the cooling threshold is satisfied.
3. **Transparent Dashboard Reporting (Web & Mobile)**:
   - Thermal safeguard events are marked with `[THERMAL_PAUSE]`.
   - The React 19 SPA displays a dedicated amber `Thermal Cooldown` pill badge rather than a generic red `Failed` badge.
   - The Flutter client (Android / Fire TV) displays `THERMAL COOLDOWN` with a thermostat icon (`Icons.thermostat_rounded`) in `AppColors.statusWarning`.

---

## 2. Changes Summary

### 2.1 Backend (Rust / Axum)
- **`rust/src/services/media_pipeline/gpu_thermal.rs`**:
  - Defined canonical marker `THERMAL_PAUSE_MARKER = "[THERMAL_PAUSE]"`.
  - Added classification function:
    ```rust
    pub fn is_thermal_safeguard_error(error_message: &str) -> bool
    ```
    Matching critical temperature aborts, sensor telemetry requirements, and thermal safeguard pauses, while strictly rejecting generic errors.
  - Added unit test `test_thermal_safeguard_error_classification`.
- **`rust/src/services/ops/job_service.rs`**:
  - In `JobService::fail(pool, id, owner, error)`:
    - Automatically checks `is_thermal_safeguard_error(error)`.
    - Prepends `[THERMAL_PAUSE] ` marker to the recorded error string.
    - Decrements `attempts = GREATEST(0, attempts - 1)`, reversing the `attempts + 1` increment from `claim_next` so thermal pauses never consume retry tokens.
- **`rust/src/services/media_pipeline/transcode_sweeper.rs`**:
  - Evaluates `is_thermal_pause`.
  - Exempts thermal pause jobs from the `existing.status == "failed" && existing.attempts >= 3` circuit breaker.
- **`rust/src/services/media_pipeline/transcode_worker.rs`**:
  - Decorated critical thermal abort and missing telemetry error strings with `THERMAL_PAUSE_MARKER`.

### 2.2 Frontend (React 19 SPA)
- **`web/src/features/transcodes/TranscodeDashboardPage.tsx`**:
  - Evaluates `isThermalPause = item.status === 'failed' && (item.error?.includes('[THERMAL_PAUSE]') ?? false)`.
  - Displays amber badge `Thermal Cooldown` with clean stripped message (removing marker prefix for user presentation).

### 2.3 Mobile & TV Client (Flutter)
- **`flutter_client/lib/features/admin/domain/models/transcode_dashboard_model.dart`**:
  - Added `final String? error;` to `TranscodeRecentJob`.
- **`flutter_client/lib/features/admin/presentation/screens/transcode_dashboard_view.dart`**:
  - Evaluates `isThermalPause`.
  - Renders `statusColor = AppColors.statusWarning` and `statusIcon = Icons.thermostat_rounded`.
  - Displays label `THERMAL COOLDOWN`.
- **`flutter_client/test/transcode_dashboard_model_test.dart`**:
  - Added test case verifying `TranscodeRecentJob` error parsing and thermal pause recognition.

---

## 3. Test & Verification Matrix

| Pillar | Test / Validation Suite | Result | Details |
|---|---|---|---|
| **Rust Backend** | `cargo test --manifest-path rust/Cargo.toml --lib` | **PASSED (139 ok, 0 failed)** | All 139 tests passed in 3.43s, including `test_thermal_safeguard_error_classification`. |
| **Rust Code Quality** | `cargo fmt --check` & `cargo clippy -D warnings` | **PASSED (0 warnings)** | Formatting verified; clippy clean on all targets in 30.45s. |
| **React 19 SPA** | `npm --prefix web run typecheck` & `npm run test` | **PASSED (338/338 tests)** | 46 test suites passed in 65s. `tsc -b` passed with 0 errors. |
| **React Production Build**| `npm --prefix web run build` | **PASSED (built in 1.66s)** | Assets bundled into `web/dist/`. |
| **Flutter Analysis** | `flutter analyze` | **PASSED (No issues found!)** | Analyzed entire Flutter client in 30.3s. |
| **Flutter Unit Tests** | `flutter test test/transcode_dashboard_model_test.dart` | **PASSED (4/4 tests passed)** | All model tests passed. |
| **Rust Release Compilation** | `cargo build --release` | **PASSED (in 2m 02s)** | Generated release binary: `rust/target/release/media-server-api.exe`. |

---

## 4. Live Verification on Active Transcode (Job 1150)

- Media: *The Odyssey (2026)* (4K UHD BluRay x265 10bit).
- At 19:23:16 IST, discrete RX 560X reached 92°C at chunk 80 (~46.5% of the 173-minute movie encoded).
- Thermal safety guard halted FFmpeg, cooled GPU down from 92°C to 65°C within seconds.
- Because `attempts` was zero-penalized, the job remained at `attempts = 0` (zero corruption attempt penalty), fully protected from the 3-attempt circuit breaker lockout.
