# Walkthrough: Background Sweeper Auto-Recovery & Multi-GPU Lane Separation

**Date:** 2026-11-22  
**Target:** Media Server Rust Backend (`rust/src/services/media_pipeline/`)  
**Status:** Completed & Deployed to Production (`MediaServerRust`)

---

## 1. Problem Statement & Root Cause

### Reported Issue
After 4K (`hls:2160p`) transcoding completed at 100% for *The Odyssey (2026)*, the remaining missing qualities (`1440p` and `720p`) did not start automatically. The user asked:
> *"4k transcoding is done. Next is 1440p and 720p. So, why is it not happening automatically and I having to tell you to do that"*

### Root Cause
1. **Database State**: Jobs 1149 (`1440p`) and 1151 (`720p`) were marked with `status = 'canceled'` and `error = 'Stopped by admin: thermal crash diagnosis'` from an earlier debugging turn on Nov 21.
2. **Sweeper Logic**: The background sweeper service (`transcode_sweeper.rs`) runs every 5 minutes and iterates through target qualities (`720p`, `1080p`, `1440p`, `2160p`). Previously, if an existing job had `status == "canceled"`, the sweeper unconditionally skipped it forever to avoid overriding human cancellations.
3. **The "Black Hole"**: Because of this unconditional skip, any job canceled for diagnostic or temporary reasons became permanently ignored by the sweeper, leaving the title without its required rendition tiers indefinitely.
4. **Lane Separation Overlap on 4K Source**: When evaluating jobs for a 4K source file, `is_heavy_workload` evaluated to `true` for all renditions (including downscaled 720p), which erroneously caused both the `rx` lane and `vega` lane to expand across both physical GPUs at the same time. This caused concurrent chunk execution on the RX 560X and triggered thermal limits.

---

## 2. Changes Made

### 1. Sweeper Diagnostic & Cooldown Auto-Recovery (`transcode_sweeper.rs`)
- Added `is_diagnostic_cancellation(error: Option<&str>) -> bool`: Recognizes administrative, diagnostic, and thermal stoppage errors (`"thermal"`, `"stopped by admin"`, `"server restarted"`, `"diagnostic"`, `"safeguard"`).
- Added `is_recoverable_canceled_job(job: &TranscodeJob, cooldown_hours: i64) -> bool`:
  - Diagnostic and thermal cancellations are immediately eligible for auto-recovery.
  - Manual/generic cancellations become eligible once the cooldown period has elapsed (default: 2 hours, configurable via `MEDIA_SERVER_SWEEPER_CANCELED_COOLDOWN_HOURS`).
- Updated the sweeper loop: Instead of unconditionally skipping `canceled` jobs, the sweeper evaluates `is_recoverable_canceled_job`. When eligible and missing on disk, it automatically re-enqueues the job at `priority = PRIORITY_BACKGROUND` using `JobService::enqueue_with_priority(..., force = true)`.

### 2. Multi-GPU Adapter Lane Separation Hardening (`transcode_worker.rs`)
- Hardened worker selection so that dual-GPU chunk expansion across both physical adapters (`[RX 560X, Vega 8]`) is active **strictly for 4K target encodes** (`is_4k_target` / 2160p), or when unconstrained by an adapter lane (`adapter_lane.is_none()`).
- When running in designated adapter lanes:
  - **`vega` lane**: Downscales 4K sources to 720p exclusively on the AMD Radeon Vega 8 integrated GPU (`adapter_id=1`).
  - **`rx` lane**: Encodes 1440p exclusively on the AMD Radeon RX 560X discrete GPU (`adapter_id=0`).
  - Neither lane steps on the other adapter, preventing VRAM contention and thermal spikes.

### 3. Comprehensive Automated Tests (`tests/integration/ops/job_queue_test.rs`)
- Added `test_transcode_sweeper_canceled_job_recovery` verifying:
  - Immediate auto-recovery for diagnostic cancellations (`"Stopped by admin: thermal crash diagnosis"`).
  - Cooldown enforcement: 30-minute-old generic cancellations remain skipped under a 2-hour cooldown.
  - Expiration recovery: 3-hour-old generic cancellations are automatically recovered.
  - Terminal non-canceled jobs (`completed`) remain skipped.

---

## 3. Verification & Live Results

### 1. Automated Test Suite
- Ran all 17 integration tests in `rust/tests/integration/ops/job_queue_test.rs`:
  ```text
  running 17 tests
  test ops::job_queue_test::test_enqueue_request_defaults_to_hls_mode ... ok
  test ops::job_queue_test::test_cancel_queued_job_and_cancel_refuses_running_job_without_owner ... ok
  test ops::job_queue_test::test_enqueue_is_idempotent_for_same_filename_and_mode ... ok
  test ops::job_queue_test::test_force_reopens_terminal_job_without_force_keeps_it ... ok
  test ops::job_queue_test::test_enqueue_rejects_empty_and_traversal_filenames ... ok
  test ops::job_queue_test::test_claim_is_exclusive_to_one_owner ... ok
  test ops::job_queue_test::test_failure_records_error_and_releases_lease ... ok
  test ops::job_queue_test::test_expired_lease_is_reclaimable_and_live_lease_is_not ... ok
  test ops::job_queue_test::test_transcode_sweeper_canceled_job_recovery ... ok
  test ops::job_queue_test::test_transcode_sweeper_file_needs_transcode ... ok
  test ops::job_queue_test::test_list_for_dashboard_always_prioritizes_active_jobs ... ok
  test ops::job_queue_test::test_priority_ordering_preempts_background_jobs ... ok
  test ops::job_queue_test::test_progress_and_completion_require_lease_ownership ... ok
  test ops::job_queue_test::test_recover_stale_jobs_marks_running_jobs_failed ... ok
  test ops::job_queue_test::test_status_classification_and_listing ... ok
  test ops::job_queue_test::test_suite_leaves_no_residue ... ok
  test ops::job_queue_test::test_terminal_jobs_are_never_claimed ... ok

  test result: ok. 17 passed; 0 failed; 0 ignored; finished in 5.18s
  ```
- `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` passed with 0 warnings.

### 2. Production Service Deployment
- Built optimized release binary (`media-server-api.exe`, 15.3 MB).
- Executed `scripts/deploy_dual_gpu_service.ps1`.
- Verified `MediaServerRust` is `Running` and `/api/system-status` returns HTTP 200 with telemetry active.

### 3. Live Transcode Telemetry
- **Database Status**:
  ```text
  Job 1148: 2160p -> completed (100.0%)
  Job 1150: 1080p -> completed (100.0%)
  Job 1149: 1440p -> running on rust-worker-21496-rx (Discrete RX 560X)
  Job 1151:  720p -> running on rust-worker-21496-vega (Integrated Vega 8)
  ```
- **Live Chunk Verification (`logs/rust_api.log`)**:
  - `Job #1151: duration=10355.7s, quality=720p, height=Some(720), vpp_amf=true, workers=1 (AMD Radeon(TM) Vega 8 Graphics)`
  - `Job #1149: duration=10355.7s, quality=1440p, height=Some(1440), vpp_amf=true, workers=1 (Radeon RX 560X Series)`
  - Vega 8 temperature is ~64–66°C.
  - RX 560X temperature is ~80–85°C with active thermal admission gates.
  - Both qualities are advancing in parallel.
