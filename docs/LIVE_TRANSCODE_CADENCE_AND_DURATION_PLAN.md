# Implementation Plan — Live Transcode Cadence and Duration Display

**Goal:** Restore the 1-second transcode progress cadence and add live duration tracking (`encoded_str / duration_str`, e.g. `58:05 / 106:10`) to the native Rust transcode engine (`MediaServerRust` `:8001`) and the React UI.

---

## 1. Context & Motivation

During 4K UHD 10-bit HEVC transcoding (*Ghost in the Cell*), the transcode engine runs 3 concurrent chunk workers across discrete AMD Radeon RX 560X and integrated Radeon Vega 8. 
Each 60-second chunk takes ~75–85 seconds to transcode on hardware.

Under the current batch execution model:
1. Progress is committed only after an entire batch of 3 chunks completes (~80 seconds per tick), causing the UI to appear frozen at static percentages (such as 37.8%) between batches.
2. When the service restarts, speed and ETA remain `null` ("calculating...") until the first post-restart batch finishes.
3. The React homepage card has a dedicated slot for `{t.encoded_str} / {t.duration_str}`, but `GET /api/transcodes` does not currently query movie duration or supply these fields.

In Flask ([`app/services/chunk_transcode_service.py`](file:///e:/MediaServer/app/services/chunk_transcode_service.py#L1251-L1260)), this was solved using a dedicated 1-second progress updater daemon (`progress_updater_loop`) and a 90-second trailing-window rate estimator (`RATE_WINDOW_S = 90.0`, `MIN_RATE_WINDOW_S = 15.0`). Porting this architecture to Rust will deliver continuous 1-second UI updates, instant ETA responsiveness, and complete movie duration tracking.

---

## 2. Scope

### In Scope
- **Backend API (`rust/src/routes/jobs.rs`):**
  - Update `active_transcodes_handler` (`GET /api/transcodes`) to query the movie's total duration from PostgreSQL (`movies.runtime` in minutes) or derive it from job progress.
  - Return `encoded_str` (e.g. `"58:05"`) and `duration_str` (e.g. `"106:10"`) in the response payload.
- **Transcode Worker Engine (`rust/src/services/transcode_worker.rs`):**
  - Implement a background cadence monitor task (`tokio::spawn`) per active job that ticks every 1.5 seconds during chunk execution.
  - Scan newly written HLS segment files on disk in real time to calculate newly encoded seconds.
  - Maintain a trailing-window sample buffer (90s window, 15s min span) to compute smoothed `speed` and remaining `eta`.
  - Update `JobService::update_progress` and disk `.progress` file on cadence, eliminating the ~80-second batch stalls.
  - Ensure background monitor tasks terminate cleanly upon job completion, failure, cancellation, or server shutdown.
- **Frontend UI (`web/src/features/library/ActiveTranscodes.tsx`):**
  - Ensure `encoded_str` and `duration_str` are mapped across both `/api/transcodes` and fallback `/api/transcode/jobs`.
  - Display the duration ratio `${encoded_str} / ${duration_str}` cleanly in the telemetry row.
  - Build production frontend bundle (`npm run build` in `web/`).

### Deliberately Out of Scope
- Deprecated Flask (`:8000`) remains strictly untouched (`AGENTS.md` §0.2).
- No changes to underlying FFmpeg command lines, DX11 adapter bindings, or AMF encoder profiles.
- No changes to HLS discontinuity tags or strided segment numbering.

---

## 3. Exit Criteria

1. **Duration Display:** `GET /api/transcodes` returns `encoded_str` and `duration_str`. The React homepage displays the ratio (e.g. `58:05 / 106:10`) on the active transcode card.
2. **1-Second Cadence:** As chunks encode, progress advances smoothly every 1–2 seconds rather than jumping in ~80-second increments.
3. **Responsive Speed & ETA:** Speed and ETA populate within 15 seconds of worker start/restart, reflecting the trailing-window rate without long stalls.
4. **Clean Concurrency & Process Safety:** Monitor tasks terminate cleanly with zero orphaned tokio tasks or database lock contention.
5. **Regression-Free Test Suite:** `cargo test` in `rust/` passes completely.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Database Lock Contention** | High-frequency progress updates locking PostgreSQL rows | Throttle database updates to 1.5-second cadence; use targeted single-row primary key updates (`WHERE id = $1`). |
| **Speed Jitter from Micro-Windows** | Unrealistic speed/ETA fluctuations | Enforce `MIN_RATE_WINDOW_S = 15.0s` before calculating initial rate, and maintain a 90-second sliding window. |
| **Missing Runtime in `movies` Table** | Fallback failure for unindexed titles | Compute `duration_sec` dynamically: if `runtime` is missing, derive duration from `ProbeService::source_video_duration` or `(encoded / percent)`. |
| **Orphaned Monitor Tasks on Worker Shutdown** | Leaked asynchronous background tasks | Use `tokio_util::sync::CancellationToken` or `Arc<AtomicBool>` to signal monitor loop teardown immediately when chunk execution concludes. |

---

## 5. Open Decisions

1. **Cadence Update Interval:**
   - *Option A:* 1.0 second (matches Flask exactly, higher database write frequency).
   - *Option B (Recommended):* 1.5 seconds (imperceptible difference in UI smoothness, 33% fewer PostgreSQL UPDATE statements).
2. **Duration Source Priority:**
   - *Option A (Recommended):* Read `movies.runtime` from PostgreSQL (instant, zero I/O disk probe) with fallback to `ProbeService` video duration.
