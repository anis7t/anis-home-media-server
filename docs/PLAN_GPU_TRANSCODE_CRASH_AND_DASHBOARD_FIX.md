# Implementation Plan — 4K Single-GPU Transcode Stability & Dashboard Telemetry Fix

**Document:** `docs/PLAN_GPU_TRANSCODE_CRASH_AND_DASHBOARD_FIX.md`  
**Date:** 2026-10-24  
**Author:** Antigravity  
**User Decision:** Preserve 4K HLS transcoding (for browser playback); eliminate dual-GPU contention by dedicating 4K transcoding to a single GPU (discrete AMD Radeon RX 560X); fix dashboard visibility for active jobs; add sweeper retry circuit breaker.

---

## 1. Problem Summary & User Directives

1. **Active Transcodes Invisible on Dashboard:**
   - `transcode_dashboard_handler` queries `JobService::list(pool, 50)`, which orders by `created_at DESC LIMIT 50`.
   - Older running jobs (like Job #776 created on Oct 17) fall outside the top 50 and become invisible, reporting "0 active transcodes".
   - **Fix:** Update the query to always select 100% of active jobs (`running` / `queued`) first, followed by recent completed/failed/canceled jobs ordered by `updated_at DESC`.
2. **System Crashes on 4K Dual-GPU Transcoding:**
   - Concurrently encoding two 4K HEVC streams across both the integrated Vega 8 (sharing APU/system memory) and discrete RX 560X saturates the laptop memory bus and triggers D3D11 driver deadlocks.
   - **User Directive:** Maintain 4K HLS transcoding so browsers can play 4K, but route 4K transcoding through a **single GPU** (the discrete RX 560X).
   - Leaving the integrated Vega 8 idle during 4K prevents display bus stalls and eliminates driver resets.
3. **Infinite Crash Loop on Failed Jobs:**
   - `transcode_sweeper.rs` automatically re-enqueued failed jobs on every 5-minute cycle without checking `attempts`.
   - **Fix:** Add a circuit breaker (`attempts < 3`) so repeatedly failing jobs do not loop indefinitely.

---

## 2. Implementation Steps

### Step 1: Fix Transcode Dashboard Job Visibility
- In `rust/src/services/job_service.rs`:
  - Add `JobService::list_for_dashboard(pool: &PgPool, limit: i64)`:
    ```sql
    WITH active AS (
        SELECT * FROM transcode_jobs 
        WHERE status IN ('running', 'queued') 
        ORDER BY priority DESC, created_at ASC
    ),
    recent AS (
        SELECT * FROM transcode_jobs 
        WHERE status NOT IN ('running', 'queued') 
        ORDER BY updated_at DESC 
        LIMIT $1
    )
    SELECT * FROM active 
    UNION ALL 
    SELECT * FROM recent;
    ```
- In `rust/src/routes/jobs.rs`:
  - Update `transcode_dashboard_handler` to call `JobService::list_for_dashboard(&state.pool, 50)`.

### Step 2: Single-GPU Execution for 4K/2160p Tiers
- In `rust/src/services/transcode_worker.rs`:
  - In `execute_job()`:
    - Inspect the job's target height / quality.
    - If `target_height >= Some(2160)` or quality is `"2160p"`:
      - Filter the `workers` list to use **only the primary discrete GPU** (Adapter 1, AMD Radeon RX 560X).
      - If no discrete GPU is available, fallback to 1 worker only.
      - Log: `Job #<id>: 4K 2160p transcode running on single dedicated GPU (<name>) to ensure system stability`.
    - For resolutions \(\le 1440\text{p}\) (1080p, 720p, 480p, 360p), continue using balanced dual-GPU concurrent workers as before.

### Step 3: Sweeper Circuit Breaker
- In `rust/src/services/transcode_sweeper.rs`:
  - When inspecting an existing failed job:
    ```rust
    if existing.status == "failed" && existing.attempts >= 3 {
        warn!("Sweeper skipping failed job for {} ({}): exceeded max attempts ({})", rel_key, mode, existing.attempts);
        stats.skipped += 1;
        continue;
    }
    ```
  - Prevents an endless crash loop if a corrupted video file or driver anomaly occurs.

### Step 4: Verification & Validation
1. Compile backend via `scripts/cargo.bat build --release`.
2. Run unit tests (`scripts/cargo.bat test --lib`).
3. Deploy updated binary to Windows Service `MediaServerRust`.
4. Verify `/api/transcode/dashboard` returns any active/queued jobs accurately.
5. Run Android API contract probe (`python scripts/probe_android_api.py`).
