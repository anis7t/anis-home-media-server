# Implementation Plan: Phase 6 Slice 3 — Transcode Single-Ownership Cutover & Real-Hardware Verification

**Date:** 2026-10-17  
**Status:** Pending User Approval  
**Governing Rules:** `AGENTS.md` §0.1, §0.2, §5; `GEMINI.md` §0, §1, §3  
**Roadmap Reference:** `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md` §Phase 6, `docs/PHASE_6_RUST_WORKER_PLAN.md` §2 (6D/6E)

---

## 1. Executive Summary & Objective

In **Phase 6 Slice 1** and **Slice 2**, we implemented the PostgreSQL-backed priority queue, crash recovery on boot, dynamic multi-GPU AMF detection (`dx11:1` RX 560X and `dx11:0` Vega 8), strided chunk planning (`stride32`), atomic playlist assembly, and the asynchronous transcode worker daemon in native Rust (`media-server-api.exe`).

The goal of **Phase 6 Slice 3** is to satisfy the canonical Phase 6 exit gate:
> *"The Rust worker passes representative hardware integration tests and failure/restart tests, and **no competing scheduler owns the same queue**."*

This requires two coordinated actions:
1. **Live Real-Hardware End-to-End Transcode Verification**: Validating real chunk generation, concurrent dual-GPU encoding, dynamic progress reporting, and clean `#EXT-X-ENDLIST` playlist sealing on actual production hardware.
2. **Flask Transcode Schedulers Retirement (Single-Ownership Cutover)**: Deactivating Flask's legacy background `auto_transcoder_loop` and converting `ensure_hls_transcode()` into a delegate that forwards admission to the Rust PostgreSQL queue, eliminating dual-scheduler contention and split-brain risks.

---

## 2. Scope

### In Scope
1. **Deactivation of Competing Flask Transcoder Schedulers**:
   - Update `app/services/worker_service.py` to disable `auto_transcoder_loop()` when `MEDIA_SERVER_DISABLE_PRECACHE=1` or `config.DISABLE_FLASK_TRANSCODING=True` is configured, logging clear delegation to Rust.
   - Update `app/services/transcode_service.py`: `ensure_hls_transcode()` checks `DISABLE_FLASK_TRANSCODING`. When enabled, it delegates any incoming call to Rust's native queue (`POST http://127.0.0.1:8001/api/transcode/jobs/{filename}`) instead of spawning Python `DualGPUTranscodeJob` processes, returning `None`.
   - Update `app/config.py` with `DISABLE_FLASK_TRANSCODING = os.getenv('DISABLE_FLASK_TRANSCODING', '1') == '1'` (defaulting to enabled, transferring sole ownership to Rust).
2. **Automated Live Real-Hardware Transcode Verification Script**:
   - Create `scripts/verify_rust_transcode_live.py`:
     - Selects a real library media file or synthetic short test video.
     - Triggers transcode via Rust API `POST /api/transcode/jobs/{filename}`.
     - Polls `GET /api/transcode-status/{filename}` and `GET /api/transcode/jobs` at 1s intervals.
     - Verifies:
       - Transition from `queued` to `running`.
       - Dual-GPU concurrent execution (`dx11:1` RX 560X and `dx11:0` Vega 8).
       - Active lease renewal heartbeats every 45s.
       - Smoothed progress, speed (x), and ETA calculations.
       - Strided segment indices (`start_seg = chunk_id * 32`).
       - Discontinuity placement (`#EXT-X-DISCONTINUITY`) and `#EXT-X-ENDLIST` terminal seal.
       - Completion state in PostgreSQL `transcode_jobs` (`status = 'completed'`).
       - Verifies that Flask spawned zero FFmpeg processes during the entire transcode run.
3. **Regression Validation**:
   - Run `scripts/probe_android_api.py --base http://127.0.0.1:8001` (confirming all 22 client endpoints remain green).
   - Run the complete Rust test suite (`job_queue_test`, `gpu_service_test`, `chunk_transcode_test`, `hls_transcode_test`, `transcode_start_test`).
   - Run Flask pytest suite to verify no regressions in unmigrated administrative/fallback pathways.

### Deliberately Out of Scope
- Port swap (`:8001` -> `:8000`) and final NSSM reconfiguration of Windows services (reserved for **Phase 7**).
- Modifying the underlying FFmpeg AMF argument generation or segment duration thresholds.
- Deleting Python media streaming and utility functions that non-transcode Flask routes still reference until Phase 7.

---

## 3. Exit Criteria

- [ ] **Single Scheduler Ownership**: Flask's `auto_transcoder_loop` is inactive; `ensure_hls_transcode()` does not spawn any FFmpeg or Python worker threads.
- [ ] **Zero Split-Brain**: At no point during an active transcode do two distinct schedulers attempt to encode or assemble the same HLS cache directory.
- [ ] **Live Hardware Verification**: `scripts/verify_rust_transcode_live.py` executes against `MediaServerRust` (`:8001`), successfully completing an end-to-end transcode with dual AMD AMF hardware encoders.
- [ ] **Playlist Correctness**: The generated `playlist.m3u8` has valid `#EXT-X-DISCONTINUITY` markers, target duration healing, `#EXT-X-ENDLIST`, and passes `ffprobe` stream validation without timeline drift.
- [ ] **Client Contract Intact**: `python scripts/probe_android_api.py --base http://127.0.0.1:8001` reports **22/22 endpoints passing**.
- [ ] **Rust Test Suite**: 36/36 tests passing via `scripts/cargo.bat test`.
- [ ] **Documentation**: `docs/MIGRATION_STATUS.md` updated to mark Phase 6 officially **COMPLETE**.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Flask and Rust dual-scheduling collision** | High (GPU lockup / corrupted HLS segments) | Make `DISABLE_FLASK_TRANSCODING=True` the default in `app/config.py`. Enforce a check in Flask's `ensure_hls_transcode()` to refuse local spawning and delegate directly to Rust. |
| **FFmpeg hang on unsupported video codec** | Medium | `TranscodeWorker` bounds execution per chunk, monitors process exit codes, and marks jobs `failed` with descriptive errors if FFmpeg exits non-zero. |
| **Long test execution time on large video files** | Low | Verification script will use a compact test clip or short movie segment to validate all dual-GPU concurrency, chunk transitions, and playlist sealing within 15–30 seconds. |
| **Windows service permission lock on restart** | Low | Provide exact `scripts/restart_rust_service.bat` and `scripts/restart_service.bat` instructions for user execution under elevated permissions. |

---

## 5. Open Decisions

1. **Test Media Asset for Live Verification**:
   - **Option A (Recommended)**: Use a lightweight (e.g. 30–60s) sample video or an existing compact library trailer to verify all GPU slots, chunk transitions, and playlist completion in ~15-30s without waiting for a full 2-hour movie.
   - **Option B**: Run verification against a full 1080p feature film from `D:\Flicks`. (Thorough, but takes several minutes to render all chunks).
   - *Recommendation*: **Option A** for deterministic, rapid automated verification, followed by non-blocking background queue inspection.

2. **Flask Rollback Capability**:
   - **Option A (Recommended)**: Guard the Flask transcode deactivation behind `DISABLE_FLASK_TRANSCODING` (default `True`), allowing instant rollback to Flask transcoding by setting `DISABLE_FLASK_TRANSCODING=0` in `.env` if ever needed.
   - **Option B**: Permanently delete `DualGPUTranscodeJob` from Flask immediately.
   - *Recommendation*: **Option A** preserves safe operational rollback while achieving 100% single-ownership in production.
