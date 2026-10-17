# Phase 6 Slice 1 Walkthrough — Transcode Job Model & Queue Ownership

**Date:** 2026-10-16  
**Status:** Verification Complete & Tested (15/15 unit/integration tests passing)  
**Branch:** `feat/rust-transcode-worker`  
**Reference Document:** [PHASE_6_SLICE_1_PLAN.md](file:///e:/MediaServer/docs/PHASE_6_SLICE_1_PLAN.md)  

---

## 1. Executive Summary & Goals Achieved

In Phase 6 Slice 1, we established native Rust ownership of the durable transcoding job model, lease mechanics, prioritization scheduling, crash recovery, and automated background library sweeping. This cleanly replaces Flask's legacy `auto_transcoder_loop` and ensures full compatibility with the strict playback gating invariant in both the Flutter TV/mobile client and the Web client (where un-transcoded media is gated until transcoding completes).

---

## 2. Deliverables & Implemented Changes

### A. Priority-Aware Job Model & Database Schema
- [models/job.rs](file:///e:/MediaServer/rust/src/models/job.rs):
  - Added `priority: i32` to [TranscodeJob](file:///e:/MediaServer/rust/src/models/job.rs#L56) and [EnqueueJobRequest](file:///e:/MediaServer/rust/src/models/job.rs#L77) (with `Default` derivation).
- [models/transcode.rs](file:///e:/MediaServer/rust/src/models/transcode.rs):
  - Expanded [TranscodeStatusResponse](file:///e:/MediaServer/rust/src/models/transcode.rs#L4) with `percent`, `remaining`, `duration`, `encoded`, `bytes` to maintain 100% contract compatibility with Flutter's `TranscodeGateDialog`.
- [db.rs](file:///e:/MediaServer/rust/src/db.rs):
  - Added idempotent DDL for `priority INTEGER NOT NULL DEFAULT 0`.
  - Added indexed query optimization: `CREATE INDEX IF NOT EXISTS transcode_jobs_claim_idx ON transcode_jobs (status, priority DESC, lease_expires_at, created_at)`.
  - Split multi-statement queries to prevent PostgreSQL prepared statement error `42601`.

### B. Core Job Service Capabilities
- [services/job_service.rs](file:///e:/MediaServer/rust/src/services/job_service.rs):
  - Defined priority constants: `PRIORITY_BACKGROUND = 0`, `PRIORITY_INTERACTIVE = 10`.
  - Implemented `enqueue_with_priority`: allows background sweeper and interactive user playback to specify priority, promoting existing queued jobs if a user requests them.
  - Updated `claim_next`: prioritizes jobs by `ORDER BY priority DESC, created_at ASC FOR UPDATE SKIP LOCKED`.
  - Implemented `recover_stale_jobs`: cleanly transitions orphaned `running` jobs on server boot to `failed` with `"Server restarted during transcode"` and releases their leases.

### C. Proactive Library Transcode Sweeper Daemon
- [services/transcode_sweeper.rs](file:///e:/MediaServer/rust/src/services/transcode_sweeper.rs):
  - `file_needs_transcode`: detects container formats requiring HLS transcoding (`.mkv`, `.avi`, `.flv`, `.ts`, etc.) vs direct playable (`.mp4`, `.m4v`, `.webm`).
  - `sweep_once`: audits the movie catalog against physical HLS caches (`playlist.m3u8` containing `#EXT-X-ENDLIST`) and enqueues missing/incomplete files at `PRIORITY_BACKGROUND`.
  - `start_daemon`: runs periodically (every 5 minutes) in the background with a 10s initial boot grace period.
- [services/mod.rs](file:///e:/MediaServer/rust/src/services/mod.rs): Exported `pub mod transcode_sweeper;`.

### D. Route Integration & Server Boot Hookup
- [routes/transcode.rs](file:///e:/MediaServer/rust/src/routes/transcode.rs):
  - Exported `pub fn video_path_key`.
  - In `transcode_start_handler`, enqueues jobs with `PRIORITY_INTERACTIVE`.
  - Synchronized `TranscodeStatusResponse` fields (`percent`, `remaining`, etc.).
- [routes/jobs.rs](file:///e:/MediaServer/rust/src/routes/jobs.rs):
  - Updated `enqueue_job_inner` and `enqueue_job_handler` to accept priority and fallback cleanly to `PRIORITY_BACKGROUND`.
- [main.rs](file:///e:/MediaServer/rust/src/main.rs):
  - On server boot, invokes `JobService::recover_stale_jobs(&pool).await`.
  - Spawns `TranscodeSweeperService::start_daemon` on a 5-minute schedule.

---

## 3. Verification & Test Outcomes

All unit and integration tests were compiled using the MSVC toolchain wrapper (`scripts/cargo.bat`) and executed against live PostgreSQL:

1. **`cargo test --test job_queue_test`** — **15 / 15 Passed (0 Failed)**
   - `test_enqueue_request_defaults_to_hls_mode` ... **ok**
   - `test_enqueue_is_idempotent_for_same_filename_and_mode` ... **ok**
   - `test_claim_is_exclusive_to_one_owner` ... **ok**
   - `test_enqueue_rejects_empty_and_traversal_filenames` ... **ok**
   - `test_expired_lease_is_reclaimable_and_live_lease_is_not` ... **ok**
   - `test_cancel_queued_job_and_cancel_refuses_running_job_without_owner` ... **ok**
   - `test_failure_records_error_and_releases_lease` ... **ok**
   - `test_transcode_sweeper_file_needs_transcode` ... **ok**
   - `test_force_reopens_terminal_job_without_force_keeps_it` ... **ok**
   - `test_priority_ordering_preempts_background_jobs` ... **ok**
   - `test_progress_and_completion_require_lease_ownership` ... **ok**
   - `test_recover_stale_jobs_marks_running_jobs_failed` ... **ok**
   - `test_status_classification_and_listing` ... **ok**
   - `test_suite_leaves_no_residue` ... **ok**
   - `test_terminal_jobs_are_never_claimed` ... **ok**

2. **`cargo test --test transcode_start_test`** — **3 / 3 Passed (0 Failed)**
   - `test_transcode_start_direct_playable_returns_ready` ... **ok**
   - `test_transcode_start_mkv_enqueues_job` ... **ok**
   - `test_transcode_start_nonexistent_file_returns_404` ... **ok**

3. **`cargo test --test hls_transcode_test`** — **10 / 10 Passed (0 Failed)**
   - `test_is_valid_segment_name` ... **ok**
   - `test_honest_target_duration_adjustment` ... **ok**
   - `test_hls_playlist_in_flight_503_retry` ... **ok**
   - `test_transcode_uncached_returns_503_and_idle_status` ... **ok**
   - `test_hls_playlist_delivery_200_and_cors` ... **ok**
   - `test_hls_segment_delivery_m4s_and_init` ... **ok**
   - `test_hls_segment_traversal_and_invalid_names_404` ... **ok**
   - `test_hls_and_transcode_options_cors` ... **ok**
   - `test_hls_segment_delivery_ts_and_range` ... **ok**
   - `test_transcode_cached_mp4_delivery` ... **ok**

---

## 4. Deployment Instructions

Per `AGENTS.md` §5 (Windows Service Privileges & NSSM Management):
Production `MediaServerRust` runs as a Windows Service under `NT AUTHORITY\SYSTEM`. Please run the elevated restart script to compile the release binary and deploy the live service:

```powershell
e:\MediaServer\scripts\restart_rust_service.bat
```

The script will stop `MediaServerRust`, release the lock on `media-server-api.exe`, run `cargo build --release`, and restart the service.

After restarting, confirm deployment by verifying the binary timestamp:
```powershell
Get-Item rust\target\release\media-server-api.exe | Select-Object LastWriteTime
```
