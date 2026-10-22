# Implementation Plan — Phase 6 Slice 2: Hardware GPU Detection & Transcode Worker Execution Engine

**Author:** Antigravity (Gemini 3.8 Flash High)  
**Date:** 2026-10-16  
**Status:** DRAFT — Awaiting User Approval  
**Branch:** `feat/rust-transcode-worker`  
**Governing Rules:** `AGENTS.md` §0.1, §0.2, §5; `GEMINI.md` §0, §1, §3  

---

## 1. Scope

### In Scope
1. **Native GPU Detection & Strategy (`rust/src/services/gpu_service.rs`):**
   - Probe D3D11 adapters on Windows (Discrete RX 560X `dx11:1` and Integrated Vega 8 `dx11:0`).
   - Validate AMF `h264_amf` hardware encoding support via short probe subprocess.
   - Fallback to CPU (`libx264`) when hardware adapters are unavailable or probing fails.
   - Implement adaptive AMF strategy selection (`select_amf_strategy`):
     - Identify 10-bit (`pix_fmt` containing `10`) or height > 1080p requiring `vpp_amf` filter downscale/conversion.
     - Enable direct zero-filter pipeline for standard 8-bit $\le$1080p sources.
   - Implement worker allocation and expansion (`expand_workers`): 1 slot for integrated GPU, remaining slots to discrete GPU.
2. **Chunk Planning & HLS Playlist Engine (`rust/src/services/chunk_transcode.rs`):**
   - Keyframe-aware chunk partitioning (`plan_chunks`): 60.0s chunk duration, 4.0s segment target duration, and strided segment indices (`start_seg = chunk_id * 32`).
   - Guard against zero-frame float residues (`dur < 1e-3s`).
   - Master playlist (`playlist.m3u8`) assembly with RFC 8216 target duration healing, `#EXT-X-START:TIME-OFFSET=0`, `#EXT-X-PLAYLIST-TYPE:EVENT` while active, and `#EXT-X-DISCONTINUITY` on chunk boundaries.
   - Parse exact segment durations from individual `chunk_{id}.m3u8` playlists.
   - Chunk output verification: ensure generated segments fall within the assigned 32-segment stride and meet minimum yield duration ratio (50%).
3. **Multi-GPU Worker Loop & Queue Consumer (`rust/src/services/transcode_worker.rs`):**
   - Background worker daemon claiming jobs via `JobService::claim_next(pool, worker_id, lease_duration)`.
   - Asynchronous FFmpeg process management using `tokio::process::Command` with Windows process safety (no `os.kill(pid, 0)`).
   - Periodic lease renewal (`JobService::renew_lease`) and progress reporting (`JobService::report_progress`) during chunk processing.
   - Graceful job cancellation handling if `JobService::cancel` is called or on server shutdown.
   - Marking completed jobs via `JobService::complete` upon verified coverage ($\ge 98\%$), or `JobService::fail` on unrecoverable errors.
4. **Integration & Server Hookup:**
   - Hook worker daemon into server boot in `rust/src/main.rs`.
   - Unit and integration tests covering chunk planning, playlist generation, GPU strategy selection, and mocked/live worker execution.

### Deliberately Out of Scope
- Modifying or extending Python code in `app/` (per `AGENTS.md` §0.2).
- Changing the public HTTP API contracts for `/api/transcode/*` or `/hls/*` (already verified and frozen).
- Altering the video delivery or Direct Play routes in `rust/src/routes/media.rs`.

---

## 2. Architecture & Execution Flow

```text
PostgreSQL `transcode_jobs`
         │ (ORDER BY priority DESC, created_at ASC FOR UPDATE SKIP LOCKED)
         ▼
[TranscodeWorker Daemon]
         │ 1. Claims job with 300s lease
         │ 2. Probes video streams (probe_service) -> determines AMF strategy
         │ 3. Plans contiguous chunks (plan_chunks with stride 32)
         ▼
   Parallel Worker Slots
   ┌───────────────────────────────────┐
   │ Slot 1: Discrete RX 560X (dx11:1) │ ──▶ Spawns FFmpeg for Chunk N
   │ Slot 2: Discrete RX 560X (dx11:1) │ ──▶ Spawns FFmpeg for Chunk N+1
   │ Slot 3: Integrated Vega 8 (dx11:0) │ ──▶ Spawns FFmpeg for Chunk N+2
   └───────────────────────────────────┘
         │
         │ While running:
         ├─▶ Renews lease every 60s
         ├─▶ Parses chunk_*.m3u8 & updates master playlist.m3u8
         ├─▶ Updates DB progress/speed/fps/eta
         ▼
[Coverage Validation & Sealing]
         │ Verified coverage >= 98%
         ├─▶ Appends #EXT-X-ENDLIST to playlist.m3u8
         └─▶ Marks job status = 'completed' in PostgreSQL
```

---

## 3. Exit Criteria

1. **GPU Adapter Enumeration & Strategy:**
   - `detect_available_gpus()` correctly detects and orders `dx11:1` (discrete) and `dx11:0` (integrated) on Windows.
   - `select_amf_strategy()` correctly enforces `vpp_amf` on 10-bit / >1080p content and allows direct encode on 8-bit 1080p content.
2. **Chunk Planning Invariant:**
   - Unit tests verify `plan_chunks` produces monotonically increasing non-overlapping segment strides (`chunk_id * 32`) with zero-frame residues rejected.
3. **Playlist Assembly Parity:**
   - Master playlist generated from chunk playlists contains RFC 8216 target duration header, `#EXT-X-START:TIME-OFFSET=0`, `#EXT-X-DISCONTINUITY` tags at chunk transitions, and valid `#EXTINF` durations.
4. **Queue & Worker Integration:**
   - Integration test verifies a queued job is claimed by the worker, executes transcode chunks, reports progress into `transcode_jobs`, seals `#EXT-X-ENDLIST`, and transitions to `completed`.
   - Cancellation test verifies cancelling a running job immediately terminates all active child FFmpeg processes and marks the job `canceled`.
5. **No Regressions:**
   - 100% of existing tests pass (`job_queue_test`, `hls_transcode_test`, `transcode_start_test`).
   - All 22 Android client probe endpoints stay green on `python scripts/probe_android_api.py --base http://127.0.0.1:8001`.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **FFmpeg Child Process Leak on Windows** | Orphaned encoding processes hog GPU/CPU after server restart or job cancel | Implement `ChildGuard` using `tokio::process::Child` with explicit `kill()` in `Drop` and cancellation listeners. Never use `os.kill(pid, 0)` (`AGENTS.md` §5). |
| **Long Transcode Lease Expiry** | A multi-hour transcode could lose its lease if the worker doesn't heartbeat | Background heartbeat task inside worker loop calls `JobService::renew_lease(pool, id, owner, 300)` every 60 seconds while transcoding is active. |
| **Keyframe / Segment Index Collision** | Non-standard GOP lengths could produce overlapping segment filenames | Enforce strided segment numbering (`chunk_id * 32`) matching Python's tested format (`segment_%06d.ts`). `_chunk_output_ok` rejects any chunk that writes beyond its 32-segment boundary. |
| **Driver Lockup on Hardware Error** | AMF encoder crash could hang the worker thread indefinitely | Add bounded execution timeout per chunk (e.g. max 180s for a 60s chunk) and retire malfunctioning GPU slot for that job. |

---

## 5. Open Decisions for User

1. **Worker Concurrency Default:**
   - In Python, `expand_workers` defaulted to 3 workers for 10-bit/4K (2 discrete + 1 integrated) and 2 workers for 8-bit (1 discrete + 1 integrated).
   - *Recommendation:* Keep this exact configuration as default, configurable via environment variables `MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10` and `MEDIA_SERVER_TRANSCODE_WORKERS_8BIT`.
2. **Worker Daemon Auto-Start:**
   - Should the background transcode worker loop start automatically on server boot alongside the sweeper daemon?
   - *Recommendation:* Yes, spawn the worker daemon in `main.rs` with graceful shutdown signal wiring.

---

## 6. Implementation Sequence

1. **Step 1: GPU Service (`rust/src/services/gpu_service.rs`)**
   - Data structures: `GpuDevice`, `GpuBackend`, `AmfStrategy`.
   - D3D11 detection and probing logic.
   - Strategy and worker expansion functions.
2. **Step 2: Chunk Planning & Playlist Assembly (`rust/src/services/chunk_transcode.rs`)**
   - Chunk specification, segment duration parser, master playlist generator with atomic write (`tempfile` + rename).
3. **Step 3: Multi-GPU Worker Orchestrator (`rust/src/services/transcode_worker.rs`)**
   - Child process management with Windows kill guard.
   - Queue claim consumer, chunk dispatcher, periodic lease renewal, and progress updater.
4. **Step 4: Tests & Verification**
   - Unit tests in `rust/tests/chunk_transcode_test.rs` and `rust/tests/gpu_service_test.rs`.
   - Full test suite run via `scripts/cargo.bat`.
   - Android client probe verification.
