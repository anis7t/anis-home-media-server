# Implementation Plan: Differentiating Generic Transcode Failures from Thermal Safeguard Pauses

**Date:** 2026-11-21  
**Author:** Antigravity  
**Target:** 100% Native Rust Backend (`rust/src/services/media_pipeline/` & `rust/src/services/ops/`)  
**Status:** DRAFT (Awaiting User Review & Sign-Off)

---

## 1. Problem Statement & Motivation

During heavy 4K UHD transcoding (such as *The Odyssey*, 173 min), discrete AMD Radeon RX 560X temperatures can intermittently touch the critical safety limit (**92.0°C**). The newly implemented **Thermal Safety Guard** successfully detects this and halts the active FFmpeg child process to protect the GPU silicon.

However, the current transcode architecture treats a thermal safeguard stop identically to a generic media failure:
1. The worker marks the job `status = 'failed'` with `JobService::fail()`.
2. Every time a worker reclaims the job from the queue, `JobService::claim_next_for_adapter` executes `attempts = attempts + 1`.
3. In `transcode_sweeper.rs`, a hard circuit breaker permanently skips retrying any job where `existing.status == "failed" && existing.attempts >= 3`.

**The Bug:** After 3 thermal cooldown pauses on a long movie, `attempts` reaches 3, causing `transcode_sweeper` to abandon the transcode permanently, mistaking a temporary physical thermal pause for a corrupt or unplayable video file.

---

## 2. Solution Architecture & Objectives

We will decouple **Thermal Safeguard Pauses** from **Generic Fatal Transcode Failures**:

| Attribute | Generic Transcode Failure | Thermal Safeguard Pause |
|---|---|---|
| **Cause** | Corrupt container, invalid bitstream, broken audio, missing codec, permanent FFmpeg error | High GPU temperature ($\ge 92^\circ\text{C}$), HWiNFO sensor telemetry requirement |
| **Max Retry Limit** | **Strictly bounded to 3 attempts** (`attempts < 3`) | **Unlimited retries** (`attempts` not penalized) |
| **Circuit Breaker** | Skipped by sweeper once `attempts >= 3` | **Exempt from sweeper circuit breaker**; always re-enqueued |
| **Attempt Accounting** | Increments database `attempts` counter | **Zero penalty**: Decrements or preserves `attempts` on thermal pause |
| **In-Flight Recovery** | N/A (aborts job) | **In-flight worker retry**: After cooling down (<75°C for 15s), worker retries the same chunk before yielding |

---

## 3. Detailed Scope of Changes

### 3.1 Error Taxonomy & Classification Helper (`rust/src/services/media_pipeline/gpu_thermal.rs` or `job_service.rs`)
- Introduce a centralized helper:
  ```rust
  pub fn is_thermal_safeguard_error(error_message: &str) -> bool {
      error_message.contains("Critical GPU temperature")
          || error_message.contains("thermal telemetry is required")
          || error_message.contains("[THERMAL_PAUSE]")
          || error_message.contains("Thermal Safeguard")
  }
  ```

### 3.2 Job Service Zero-Penalty Accounting (`rust/src/services/ops/job_service.rs`)
- In `JobService::fail(pool, id, owner, error)`:
  - If `is_thermal_safeguard_error(error)`:
    - Instead of leaving `attempts` incremented, adjust `attempts = GREATEST(0, attempts - 1)`.
    - Prefix error with `[THERMAL_PAUSE] ` for clear auditing and dashboard visibility.
  - This guarantees that thermal pauses never consume the user's 3 corruption retry tokens.

### 3.3 Transcode Sweeper Circuit Breaker Exemption (`rust/src/services/media_pipeline/transcode_sweeper.rs`)
- Update line 181 of `transcode_sweeper.rs`:
  ```rust
  let is_thermal_pause = existing.error.as_deref().map(is_thermal_safeguard_error).unwrap_or(false);

  // Circuit breaker: do not endlessly re-enqueue jobs that repeatedly failed with fatal errors (corrupt file).
  // Thermal safeguard pauses have UNLIMITED retries.
  if existing.status == "failed" && existing.attempts >= 3 && !is_thermal_pause {
      debug!(
          "Sweeper skipping failed job for {} ({}): exceeded max attempts ({})",
          rel_key, mode, existing.attempts
      );
      stats.skipped += 1;
      continue;
  }
  ```

### 3.4 In-Flight Worker Cooldown & Retry (`rust/src/services/media_pipeline/transcode_worker.rs`)
- In `transcode_worker.rs` chunk loop:
  - When `critical_temperature_or_sensor_loss` aborts an active FFmpeg process:
    - Log: `"Active chunk stopped due to GPU temperature (>=92C); entering in-flight cooldown breather..."`
    - Wait up to 30 seconds for GPU temperature to fall below 75°C (polling every 2s).
    - If temperature drops below 75°C, retry encoding the same chunk (up to 2 in-flight chunk retries) before giving up the lease.
    - If it must yield the job to the queue, call `JobService::fail(pool, job_id, worker_id, "[THERMAL_PAUSE] Critical GPU temperature reached; yielding for system cooldown")`.

---

## 4. Verification Plan & Test Strategy

1. **Unit Tests**:
   - `test_thermal_safeguard_error_classification`: Assert that thermal and telemetry errors match, while FFmpeg exit code 1 / corrupt file errors do not.
   - `test_thermal_pause_does_not_increment_attempts`: Calling `JobService::fail` with a thermal pause restores `attempts`.
   - `test_sweeper_circuit_breaker_exempts_thermal_pauses`: Sweeper skips generic failed jobs with `attempts = 3`, but re-enqueues thermal pause jobs even with `attempts >= 3`.
2. **Local Parity Verification (4 Pillars)**:
   - Rust: `cargo fmt --check`, `cargo clippy -D warnings`, and `cargo test --lib`.
   - Web: `npm run typecheck` & `npm run test`.
   - Flutter: `flutter analyze` & `flutter test`.
3. **Live Job 1150 Validation**:
   - Verify Job 1150 maintains `attempts = 0` and continues uninterrupted towards 100% completion.

---

## 5. Risks & Mitigations

- **Risk**: An endless loop if cooling fails or fans die completely.  
  **Mitigation**: Admission checks (`rx_temp_c < 85.0`) prevent worker admission if the GPU cannot cool down below 85°C.
- **Risk**: Regression of corrupt file circuit breaker.  
  **Mitigation**: Unit tests explicitly verify that non-thermal errors (e.g. exit code 1, invalid data, missing streams) remain strictly capped at 3 attempts.
