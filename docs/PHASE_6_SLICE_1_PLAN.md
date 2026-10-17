# Implementation Plan: Phase 6 Slice 1 — Transcode Job Model & Queue Ownership in Rust

**Date**: 2026-10-16  
**Status**: Pending User Approval  
**Governing Documents**: `AGENTS.md` §0.1, `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md` §5 Phase 6  

---

## 1. Overview & Context

With the reverse-proxy bridge completely retired in Phase C5, all HTTP endpoints are natively hosted by Axum on `:8001`. The next major milestone on the canonical migration roadmap is **Phase 6: Transcode Worker & GPU Queue Ownership in Rust**.

Transcoding in this media server converts non-web-native containers (MKV, AVI, etc.) and non-native codecs (HEVC, AC3, DTS) into high-performance HLS streams using chunked dual-GPU AMD AMF encoding.

To ensure zero downtime, prevent dual-scheduler split-brain, and avoid orphaned FFmpeg processes, Phase 6 is divided into structured slices:
- **Slice 1 (This Plan)**: Transcode Job Model, Atomic Queue Ownership, Leases & Status API.
- **Slice 2**: Multi-GPU AMF FFmpeg Worker Execution Engine (`dx11:1` RX 560X and `dx11:0` Vega 8).
- **Slice 3**: HLS Dynamic Assembly, End-to-End Playback Integration & Retiring Python Transcode Service.

---

## 2. Scope of Slice 1

### In Scope
1. **PostgreSQL Schema Verification & Evolution**:
   - Ensure the `transcode_jobs` table in PostgreSQL has robust columns for queue scheduling:
     - `id` (serial / bigserial primary key)
     - `filename` (text, not null)
     - `target_resolution` (text, default '1080p')
     - `status` (`'queued'`, `'running'`, `'completed'`, `'failed'`, `'cancelled'`)
     - `worker_id` (text, nullable — unique identifier of the claiming worker)
     - `heartbeat_at` (timestamptz, nullable — worker liveness leases)
     - `progress` (double precision, default 0.0)
     - `speed` (double precision, nullable)
     - `fps` (double precision, nullable)
     - `eta_seconds` (integer, nullable)
     - `error_message` (text, nullable)
     - `created_at`, `started_at`, `completed_at` (timestamptz)
2. **Rust Domain Models (`rust/src/models/transcode.rs`)**:
   - `TranscodeJob`, `TranscodeStatusResponse`, `TranscodeJobSummary`, `JobClaim`.
3. **Rust Transcode Queue Service (`rust/src/services/transcode_queue_service.rs`)**:
   - `enqueue_job(filename, resolution)`: Idempotent queue insertion (returns existing active job if already queued/running).
   - `claim_next_job(worker_id, lease_duration)`: Atomically claims the next pending job using PostgreSQL `SELECT ... FOR UPDATE SKIP LOCKED` and sets `status = 'running'`.
   - `renew_lease(job_id, worker_id)`: Heartbeat mechanism for active workers to renew leases.
   - `update_progress(job_id, progress, speed, fps, eta)`: Persists granular transcode status.
   - `complete_job(job_id)`: Marks job `'completed'`.
   - `fail_job(job_id, error)`: Marks job `'failed'` with error description.
   - `cancel_job(job_id_or_filename)`: Marks job `'cancelled'`.
   - `recover_stale_jobs()`: Called on server startup to mark abandoned `'running'` jobs (without active heartbeat) as `'failed'` or re-queue them.
4. **API Route Handlers (`rust/src/routes/transcode.rs`)**:
   - `GET /api/transcode-status/{*filename}`: Consolidated native status handler reporting live job status and progress.
   - `POST /api/transcode/start/{*filename}`: Upgraded to use `TranscodeQueueService::enqueue_job`.
   - `POST /api/transcode/cancel/{*filename}`: Safely cancels active or queued jobs.
   - `GET /api/transcode/queue`: Administrator view of queued and running jobs.
5. **Automated Testing Suite (`rust/tests/transcode_queue_test.rs`)**:
   - Atomic job claim concurrency test (two workers competing for jobs cannot claim the same row).
   - Idempotent enqueue test.
   - Stale job startup recovery test.
   - Status endpoint contract test.

### Deliberately Out of Scope (Deferred to Slice 2)
- Spawning actual `ffmpeg.exe` processes or AMF hardware encoders (Slice 2).
- Dynamic chunk splitting and GPU chunk scheduler (Slice 2).

---

## 3. Exit Criteria

1. **Compilation & Static Checks**: `cargo check` and `cargo test` pass with 0 errors.
2. **Automated Unit & Integration Tests**:
   - `transcode_queue_test.rs` validates atomic claiming (`FOR UPDATE SKIP LOCKED`), idempotent queuing, status reporting, and stale job recovery.
   - `transcode_start_test.rs` and `probe_android_api.py` remain 100% passing.
3. **Database Concurrency Safety**:
   - Job claims are guaranteed serialized and race-free in PostgreSQL under concurrent worker simulations.
4. **Client Contract Compatibility**:
   - Flutter and React clients query `/api/transcode-status/{*filename}` and `/api/transcode/start/{*filename}` with zero behavioral divergence.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Competing Workers / Split-Brain** | Duplicate transcode runs corrupting HLS directory | Use PostgreSQL `FOR UPDATE SKIP LOCKED` in `claim_next_job`, ensuring each queued job is acquired by at most one worker thread. |
| **Worker Crash / Abandoned Jobs** | Job stuck indefinitely in `'running'` state | Implement worker heartbeat leases and startup recovery (`recover_stale_jobs`), resetting orphaned jobs. |
| **Database Lock Contention** | High-frequency progress updates locking rows | Throttle progress updates to PostgreSQL (e.g. 1-second cadence) or use non-locking atomic updates on `transcode_jobs`. |
| **Flutter Client Regressions** | Mobile/TV transcode trigger fails | Maintain exact schema expected by Flutter client (`status`, `progress`, `speed`, `fps`, `eta`). |

---

## 5. Open Decisions for User

1. **Stale Job Recovery Policy on Startup**:
   - *Option A (Recommended)*: Mark orphaned `'running'` jobs as `'failed'` with `"Server restarted during transcode"` so users or automated players can cleanly re-request them.
   - *Option B*: Automatically reset orphaned `'running'` jobs back to `'queued'` so they resume without user action.
   *(Recommendation: Option A — prevents infinite retry loops if a specific video triggered a crash).*
