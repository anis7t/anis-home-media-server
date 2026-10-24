# Phase 6 Slice 2 Walkthrough — Hardware GPU Detection & Transcode Worker Execution Engine

**Date:** 2026-10-16  
**Status:** Verification Complete & Tested (All GPU, Chunking, Transcode & Queue tests passing)  
**Branch:** `feat/rust-transcode-worker`  
**Reference Document:** [PHASE_6_SLICE_2_WORKER_ENGINE_PLAN.md](file:///e:/MediaServer/docs/PHASE_6_SLICE_2_WORKER_ENGINE_PLAN.md)  

---

## 1. Executive Summary & Goals Achieved

In **Phase 6 Slice 2**, we completed the migration of the hardware GPU detection, AMF hardware encoding validation, adaptive strategy allocation, strided chunk planning, discontinuity-mapped master playlist generation, and the multi-GPU chunk worker daemon to native Rust.

All deliverables were validated against live PostgreSQL and Windows DirectX 11 hardware abstractions:
- **Zero regressions:** `job_queue_test` (15/15), `chunk_transcode_test` (4/4), `gpu_service_test` (4/4), `transcode_start_test` (3/3), and `hls_transcode_test` (10/10) all pass cleanly.
- **Contract Parity:** The strided segment layout (`chunk_id * 32`) and keyframe alignment preserve historical cache compatibility and eliminate cross-chunk segment overwrites.

---

## 2. Deliverables & Implemented Changes

### A. Hardware GPU Detection & Adaptive AMF Strategy
- [services/gpu_service.rs](file:///e:/MediaServer/rust/src/services/gpu_service.rs):
  - `probe_d3d11_adapter`: checks discrete adapter (`dx11:1`) and integrated adapter (`dx11:0`) via bounded `h264_amf` lavfi probe subprocess.
  - `detect_available_gpus`: caches detected adapters and orders discrete GPU first.
  - `select_amf_strategy`:
    - Enforces `vpp_amf` scaling/depth conversion for 10-bit (`pix_fmt` containing `"10"`) or height > 1080p (allocating 3 workers).
    - Enables direct zero-filter encoding for 8-bit $\le$1080p sources (allocating 2 workers).
  - `expand_workers`: assigns 1 slot to the integrated GPU and weights all remaining slots to the discrete GPU with unique names (`RX 560X`, `RX 560X#2`).
- [services/probe_service.rs](file:///e:/MediaServer/rust/src/services/probe_service.rs):
  - Added `pix_fmt` and `r_frame_rate` fields to `ProbeStream` to allow instant stream inspection for AMF strategy selection.

### B. Strided Chunk Planning & Master Playlist Assembly
- [services/chunk_transcode.rs](file:///e:/MediaServer/rust/src/services/chunk_transcode.rs):
  - `plan_chunks`: keyframe-aware 60s windows with strided segment indices (`start_seg = chunk_id * 32`). Rejects zero-frame float residues (`< 1e-3s`).
  - `parse_chunk_segment_durations`: extracts real durations from `#EXTINF:<dur>` tags in individual `chunk_{id}.m3u8` playlists.
  - `chunk_output_ok`: verifies produced segments stay within the 32-segment boundary stride and yield $\ge 50\%$ of planned duration.
  - `update_master_playlist`: writes contiguous master playlist, inserting `#EXT-X-DISCONTINUITY` before chunk transition segments and `#EXT-X-ENDLIST` on completion. Atomically writes via tempfile + rename and stamps `.seg_layout` (`stride32`).

### C. Multi-GPU Transcode Worker Daemon
- [services/transcode_worker.rs](file:///e:/MediaServer/rust/src/services/transcode_worker.rs):
  - Claims jobs via `JobService::claim_next(pool, worker_id, 300)`.
  - Distributes pending chunks across GPU slots with bounded concurrency.
  - Executes FFmpeg via `tokio::process::Command` with Windows process-safe termination (no `os.kill(pid, 0)`).
  - Heartbeat lease renewal every 45s (`JobService::renew_lease`).
  - Progress and speed calculation with database updates via `JobService::update_progress`.
  - Automatic completion sealing (`JobService::complete`) upon reaching $\ge 98\%$ media coverage.
- [main.rs](file:///e:/MediaServer/rust/src/main.rs):
  - Spawns `TranscodeWorker::start_worker` on boot with graceful shutdown wiring.

---

## 3. Verification & Test Outcomes

All unit and integration tests were executed via the MSVC toolchain wrapper (`scripts/cargo.bat`):

1. **`cargo test --test gpu_service_test`** — **4 / 4 Passed (0 Failed)**
   - `test_is_ten_bit_detection` ... **ok**
   - `test_select_amf_strategy_requirements` ... **ok**
   - `test_expand_workers_discrete_and_integrated_allocation` ... **ok**
   - `test_ffmpeg_arguments_generation` ... **ok**

2. **`cargo test --test chunk_transcode_test`** — **4 / 4 Passed (0 Failed)**
   - `test_plan_chunks_empty_or_zero` ... **ok**
   - `test_plan_chunks_stride_and_boundary_invariants` ... **ok**
   - `test_plan_chunks_drops_zero_frame_float_residue` ... **ok**
   - `test_update_master_playlist_discontinuities_and_healing` ... **ok**

3. **`cargo test --test job_queue_test`** — **15 / 15 Passed (0 Failed)**
   - All 15 tests passed, including priority preemption and startup crash recovery.

4. **`cargo test --test hls_transcode_test`** — **10 / 10 Passed (0 Failed)**
   - All 10 HLS segment and playlist tests passed.

5. **`cargo test --test transcode_start_test`** — **3 / 3 Passed (0 Failed)**
   - All 3 transcode start handler tests passed.

---

## 4. Deployment Instructions

Per `AGENTS.md` §5 (Windows Service Privileges & NSSM Management):
To deploy the new multi-GPU worker execution engine to the production `MediaServerRust` Windows Service:

1. Run the service restart batch script:
   ```cmd
   e:\MediaServer\scripts\restart_rust_service.bat
   ```
2. Verify the binary timestamp per `AGENTS.md` §5:
   ```powershell
   Get-Item rust\target\release\media-server-api.exe | Select-Object LastWriteTime
   ```
3. Run the Android API contract probe to ensure all 22 client endpoints remain 100% green:
   ```powershell
   python scripts/probe_android_api.py --base http://127.0.0.1:8001
   ```
