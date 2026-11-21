# Implementation Plan: Background Transcode Sweeper Optimization for Canceled Jobs & Rendition Progression

**Date:** 2026-11-22  
**Target:** Media Server Rust Backend (`rust/src/services/media_pipeline/transcode_sweeper.rs`, `rust/src/services/ops/job_service.rs`) & Database Operations  
**Status:** DRAFT (Awaiting User Approval)

---

## 1. Executive Summary & Root Cause Analysis

### Problem Statement
Transcoding of 4K (`hls:2160p`) for *The Odyssey (2026)* completed at 100% progress. However, the remaining missing quality tiers (`1440p` and `720p`) did not start automatically. The user asked:
> *"4k transcoding is done. Next is 1440p and 720p. So, why is it not happening automatically and I having to tell you to do that"*

### Root Cause
1. **Database State**: In PostgreSQL table `transcode_jobs`, entries for *The Odyssey* already existed for all four qualities:
   - Job 1148 (`hls:2160p`): `status = 'completed'` (100% done)
   - Job 1150 (`hls:1080p`): `status = 'completed'` (100% done)
   - Job 1149 (`hls:1440p`): `status = 'canceled'`, error: `"Stopped by admin: thermal crash diagnosis"`
   - Job 1151 (`hls:720p`): `status = 'canceled'`, error: `"Stopped by admin: thermal crash diagnosis"`
2. **Sweeper Logic (`transcode_sweeper.rs` lines 176–179)**:
   ```rust
   if existing.status == "canceled" {
       stats.skipped += 1;
       continue;
   }
   ```
   The background sweeper service runs every 5 minutes. It iterates through all library videos and checks missing qualities (`720p`, `1080p`, `1440p`, `2160p`).
   - If no row exists (`Ok(None)`), it automatically queues the job.
   - If an existing row has `status == "canceled"`, it **unconditionally skips** it forever.
3. **The "Black Hole" Effect**:
   Because Jobs 1149 and 1151 were canceled during an earlier debugging turn to isolate 1080p and 4K thermal crash testing, the sweeper assumed that an administrator intentionally canceled these qualities and permanently refused to touch them. As a result, *The Odyssey* was left permanently without 1440p and 720p renditions, requiring manual intervention.

---

## 2. Proposed Architecture & Solution

### A. Immediate Operational Action: Re-queue *The Odyssey* 1440p & 720p
Reset Jobs 1149 and 1151 in PostgreSQL:
```sql
UPDATE transcode_jobs
   SET status = 'queued',
       attempts = 0,
       error = NULL,
       lease_owner = NULL,
       lease_expires_at = NULL,
       updated_at = CURRENT_TIMESTAMP
 WHERE id IN (1149, 1151);
```
- **Automatic Multi-GPU Lane Allocation**:
  - **Job 1151 (`720p`)**: Immediately claimed by the **Vega 8** adapter lane (`rust-worker-*-vega`) to transcode on the iGPU.
  - **Job 1149 (`1440p`)**: Immediately claimed by the **RX 560X** adapter lane (`rust-worker-*-rx`) to transcode on the dGPU.
  - Both will execute concurrently with active per-adapter thermal safeguards (85°C admission limit, 75°C cooldown wait, 92°C hardkill).

### B. Sweeper Logic Enhancement (`transcode_sweeper.rs`)
Upgrade the background sweeper to differentiate between permanent human dismissals and recoverable/diagnostic cancellations:
1. **Disk Completion Priority**:
   If the quality playlist (`playlist.m3u8`) exists on disk and contains `#EXT-X-ENDLIST`, it is complete and skipped.
2. **Diagnostic Cancellation Auto-Recovery**:
   If a job is marked `canceled` with an error indicating an automated, diagnostic, or thermal stoppage (e.g., error contains `"thermal"`, `"Stopped by admin"`, `"Server restarted"`, or `"diagnostic"`), the sweeper treats it as recoverable and automatically re-enqueues it with `force = true` at `priority = PRIORITY_BACKGROUND`.
3. **Canceled Job Cooldown Expiration (TTL)**:
   For generic cancellations (e.g. canceled from UI during high load), if the job has been in `canceled` status for longer than `MEDIA_SERVER_SWEEPER_CANCELED_COOLDOWN_HOURS` (default: 2 hours) AND its HLS stream remains incomplete on disk, the sweeper re-enqueues it at low priority. This prevents a temporary cancel from permanently denying renditions for a title.
4. **Immediate Library Scan Re-evaluation**:
   When a manual library scan ("↻ Scan") is triggered, any missing renditions for existing media are automatically re-enqueued.

---

## 3. Scope of Changes

### What Changes:
1. **`rust/src/services/media_pipeline/transcode_sweeper.rs`**:
   - Replace the blanket `if existing.status == "canceled" { continue; }` with `is_recoverable_canceled_job(&existing, cooldown_duration)`.
   - Re-enqueue recoverable canceled jobs via `JobService::enqueue_with_priority(pool, &rel_key, &mode, true, priority)`.
2. **Database Operation**:
   - Re-queue Jobs 1149 and 1151 for *The Odyssey (2026)*.
3. **Automated Unit & Integration Tests**:
   - Add test coverage in `tests/integration/ops/` verifying:
     - Diagnostic canceled jobs are re-enqueued by the sweeper.
     - Freshly canceled jobs within the cooldown window remain skipped.
     - Expired canceled jobs with missing renditions are re-enqueued.

### What Deliberately Does Not Change:
- Completed jobs (`status == 'completed'` with `#EXT-X-ENDLIST`) remain untouched and skipped.
- Live jobs (`queued` or `running`) remain untouched.
- Circuit breaker for repeatedly failing corrupt bitstreams (`status == 'failed' && attempts >= 3 && !is_thermal_pause`) remains strictly in effect.
- Dual-GPU lane assignment rules (Vega 8 for 720p, RX 560X for 1080p/1440p/2160p) remain unchanged.

---

## 4. Exit Criteria

1. **The Odyssey Transcoding**:
   - Job 1151 (`hls:720p`) claimed by Vega 8 lane (`rust-worker-*-vega`) and begins chunk generation.
   - Job 1149 (`hls:1440p`) claimed by RX 560X lane (`rust-worker-*-rx`) and begins chunk generation.
   - Both proceed concurrently with temperature telemetry verified under 85°C.
2. **Sweeper Code Verification**:
   - `cargo check --manifest-path rust/Cargo.toml` and `cargo test --manifest-path rust/Cargo.toml` pass with zero errors and zero warnings.
3. **Production Deployment**:
   - Rebuilt binary deployed to `MediaServerRust` Windows service cleanly.
   - Verification that future canceled diagnostic jobs are automatically recovered on subsequent sweeper cycles.

---

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **User cancels job from UI, but sweeper immediately re-adds it** | Annoyance / loop | The 2-hour cooldown window ensures UI cancellations are respected. Sweeper only re-evaluates after 2 hours if media is still missing on disk. |
| **Thermal overload running 1440p and 720p concurrently** | System thermal throttle | Discrete RX 560X handles 1440p; integrated Vega 8 handles 720p. Each worker independently monitors its own adapter temperature via HWiNFO64 (85°C admission, 75°C cooldown, 92°C hardkill). |
| **Database lock contention during sweeper batch re-enqueue** | Service latency | `enqueue_with_priority` uses row-level locking (`FOR UPDATE SKIP LOCKED`) and short-lived transactions. |

---

## 6. Open Decisions for User

1. **Immediate Execution**:
   - Should we re-queue Jobs 1149 and 1151 in PostgreSQL immediately so 1440p and 720p start encoding right now, while we implement and test the sweeper code change? *(Recommended: Yes)*
2. **Cooldown Duration**:
   - Should the sweeper cooldown for user-canceled jobs be 2 hours (Recommended), 4 hours, or 24 hours?
