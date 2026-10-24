# Phase 6 Plan: Rust Transcoding Worker / Orchestrator

**Status:** Sliced plan approved, **6A in progress**
**Branch:** `feat/rust-api-foundation`
**Governing documents:** [`FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 6, `AGENTS.md`

---

## 1. What exists today (verified, 2026-10-16)

| Concern | Owner | Location |
|---|---|---|
| Job admission | Flask | `ensure_hls_transcode()` `app/services/transcode_service.py:1609` |
| Admission call sites | Flask | `routes/api.py:357,614`, `routes/media.py:344`, `routes/upload.py:135`, `worker_service.py:66,104` |
| Auto queue loop | Flask | `auto_transcoder_loop()` `app/services/worker_service.py:85` |
| Chunk scheduling + FFmpeg | Flask | `DualGPUTranscodeJob` `app/services/chunk_transcode_service.py:255` (1215 lines) |
| GPU telemetry | Flask | `app/services/gpu_service.py` (258 lines) |
| Status read | **Rust** | `routes/transcode.rs:83` — **filesystem-derived, no job state** |
| Queue / leases / job records | **nobody** | — |

**The gap that makes this risky today.** Job ownership lives only in Flask
process memory (`config.HLS_PROCESSES`, `config.TRANSCODE_LOCKS`). Two
processes can each believe they own the same title: `ensure_hls_transcode`
is guarded only by an in-memory lock, and its cross-process duplicate check
(`find_ffmpeg_info_for_path`) enumerates processes via `psutil` — which
**cannot read a LocalSystem process's command line** from a user process.
So neither the lock nor the scan is authoritative across the Flask/Rust
boundary. Rust serving `/api/transcode-status` while Flask spawns the
encoders is a split-brain waiting to happen, and it is exactly the failure
the roadmap names *Critical*.

## 2. Slice map

Each slice is independently reviewable and independently reversible. No
slice changes FFmpeg command generation, encoders, GPU mappings, chunking
strategy, or output checks (roadmap rule 8).

### 6A — Job model & queue ownership (no FFmpeg)
* `transcode_jobs` table in PostgreSQL, idempotent DDL applied at pool
  creation (`db.rs`), since the crate has no migration runner.
* `JobService`: enqueue (idempotent per filename+mode), `claim_next` with
  an atomic conditional `UPDATE ... RETURNING`, lease renew/heartbeat,
  complete, fail, cancel, get-by-filename, list.
* Routes: `POST /api/transcode/jobs/{filename}`, `POST
  /api/transcode/jobs/{filename}/cancel`, `GET /api/transcode/jobs`, and
  `/api/transcode-status/{filename}` extended to prefer a live job row and
  **fall back to the current filesystem derivation when no row exists** —
  so no playback behaviour changes.
* Deliberately spawns nothing. Proves ownership and durability without
  touching content.
* Exit gate: queue semantics tested (dedupe, exclusive claim, lease-expiry
  reclaim, cancel, complete, fail); status endpoint byte-identical when no
  job row; zero test rows persist.

### 6B — Chunk planning & layout parity (pure functions, no spawn)
* Port `plan_chunks`, `MIN_PLANNABLE_CHUNK_SECONDS = 1e-3`,
  `SEGMENTS_PER_CHUNK_STRIDE = 32`, the `.seg_layout` marker, cache-dir
  resolution, `_hls_resume_point`, `honest_target_duration`, and
  `source_video_duration` (ffprobe; the video-stream end, never a
  container duration, and never with a non-`None` fallback).
* Tests are **parity tests against the Python implementation** over a
  duration residue sweep, asserting structural identity of chunk ids and
  segment ranges — not re-derived expectations.
* Exit gate: zero divergence from Python across the sweep, including the
  degenerate-tail case that once retired a GPU worker at the end of an
  otherwise healthy run.

### 6C — FFmpeg spawn & monitor (single worker, real hardware)
* Spawn one chunk with the **exact** current command shape (AMF, `-gop`,
  `-force_key_frames`, `-output_ts_offset`), parse `-progress`, track
  pids, cancel targeting the correct pid, clean partial output.
* Exit gate: a real chunk renders frame-complete; cancel kills the right
  process; no orphaned ffmpeg survives.

### 6D — Dual-GPU scheduling, frame accounting, sealing
* Worker pool across both GPUs with **distinct worker names** (the
  scheduler retires by name, so shared names take down every duplicate).
* Frame accounting using the ported shared helpers; `unknown (-1)` never
  treated as empty; ENDLIST refused past per-chunk tolerance or the
  aggregate ceiling; accepted shortfall recorded to `hls.loss.json`.
* Exit gate: a finished transcode with **zero missing frames**, ENDLIST
  written, no `hls.loss.json` — `missing_frames <= 0`, never `== 0`.

### 6E — Cutover of ownership & Flask transcode retirement
* Rust becomes the **single** scheduler: Flask's `ensure_hls_transcode`
  admission and `auto_transcoder_loop` disabled behind a flag, in that
  order, with Flask retained for rollback.
* Exit gate: `scripts/probe_android_api.py` 18/18 against `:8001`; a
  monitored window with no duplicate FFmpeg on any cache; then Flask
  transcode paths deleted.

## 3. Non-negotiables carried into every slice

* **Never** treat `-1`/unknown as zero frames (caused unbounded
  re-rendering at ~2x the elapsed cost).
* **Never** walk segment indices densely from 0 — glob and bound by
  `start_seg + SEGMENTS_PER_CHUNK_STRIDE`.
* **Never** raise `MIN_PLANNABLE_CHUNK_SECONDS` toward a round number; a
  ~1e-13 s tail window is unrenderable at any rate.
* **Never** write ENDLIST from label arithmetic, and never from a
  predicate that mutates.
* **Never** derive a completeness decision from a container duration.
* **Test isolation**: every suite cleans its rows in setup *and* teardown;
  zero phantom rows in `media_server`.