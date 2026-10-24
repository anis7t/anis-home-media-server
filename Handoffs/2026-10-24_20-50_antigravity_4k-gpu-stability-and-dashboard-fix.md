# Session Handoff — 2026-10-24 20:50 IST — 4K GPU Stability & Dashboard Telemetry Fix

**Author / Agent:** Antigravity (Gemini 3.8 Flash)  
**Topic:** Post-mortem of the three 10/24 hard system restarts; resolution of the dual-GPU 4K HEVC contention; fix for the transcode dashboard active job visibility blindspot; sweeper retry circuit breaker.  
**Working Directory:** `E:\MediaServer`  
**Status:** ✅ **Investigated, Fixed, Verified, and Deployed.**  

---

## 1. What This Session Produced

1. **Root Cause Analysis of 3 Hard Crashes:**
   - Identified 3 unexpected shutdowns in Windows System Event Log (Event ID 6008 at 18:50:31, 19:34:27, 19:58:56 IST).
   - Proved via `logs/rust_api.log` that all 3 crashes occurred during active 4K HEVC (`hevc_amf`) chunk transcoding of *Ghost in the Cell* (Job #776) running simultaneously across both GPUs.
   - Identified the infinite crash loop: the background sweeper re-enqueued the failed 4K job on every server restart.
2. **Root Cause Analysis of Dashboard Showing 0 Active Transcodes:**
   - Proved that `transcode_dashboard_handler` used `JobService::list(pool, 50)`, which ordered by `created_at DESC LIMIT 50`.
   - Because Job #776 was created on Oct 17 and over 60 jobs were created after it, it was truncated from the query and rendered invisible while actively running.
3. **Hardening Applied:**
   - **Dashboard Query Fix:** Created `JobService::list_for_dashboard` with a CTE prioritizing 100% of active/queued jobs first, and sorting completed jobs by `updated_at DESC`.
   - **4K Single Dedicated GPU Enforcement:** Preserved 4K HLS transcoding per user directive, but restricted 4K HEVC tiers to 1 dedicated worker on the discrete AMD Radeon RX 560X (`MEDIA_SERVER_TRANSCODE_WORKERS_4K=1`). Integrated Vega 8 remains free for display and desktop rendering.
   - **Sweeper Circuit Breaker:** Updated `TranscodeSweeperService` to skip canceled jobs and failed jobs with `attempts >= 3`.
4. **Verification:**
   - Unit tests: `gpu_service` (6/6 pass).
   - Integration tests: `job_queue_test` (1/1 pass).
   - Android API contract probe: `probe_android_api.py` (22/22 pass).
   - Live service restarted and verified on port 8000; dashboard accurately reflects jobs.

---

## 2. Deliverables & Documentation

- Implementation Plan: [`docs/PLAN_GPU_TRANSCODE_CRASH_AND_DASHBOARD_FIX.md`](../docs/PLAN_GPU_TRANSCODE_CRASH_AND_DASHBOARD_FIX.md)
- Walkthrough: [`docs/WALKTHROUGH_GPU_TRANSCODE_CRASH_AND_DASHBOARD_FIX.md`](../docs/WALKTHROUGH_GPU_TRANSCODE_CRASH_AND_DASHBOARD_FIX.md)
- Core Code Updated:
  - [`rust/src/services/job_service.rs`](../rust/src/services/job_service.rs)
  - [`rust/src/routes/jobs.rs`](../rust/src/routes/jobs.rs)
  - [`rust/src/services/gpu_service.rs`](../rust/src/services/gpu_service.rs)
  - [`rust/src/services/transcode_worker.rs`](../rust/src/services/transcode_worker.rs)
  - [`rust/src/services/transcode_sweeper.rs`](../rust/src/services/transcode_sweeper.rs)
  - [`.env`](../.env)
