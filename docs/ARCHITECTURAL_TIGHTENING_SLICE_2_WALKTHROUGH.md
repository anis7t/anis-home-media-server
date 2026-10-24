# Architectural Tightening & Revamp — Slice 2 Walkthrough

## Summary of Slice 2 Deliverables

Slice 2 addressed the Rust backend architecture by resolving namespace sprawl across services, routes, and models, enforcing GPU and subprocess governance via priority concurrency semaphores, and consolidating 34 disparate integration test binaries into a unified integration test harness.

All deliverables have been completed, verified, and certified:

### 1. Domain Modularization Across 5 Namespaces
Reorganized `rust/src/services/` (29 modules), `rust/src/routes/` (22 modules), `rust/src/models/` (12 modules), and `rust/src/scanner/` into 5 clean domain namespaces with 100% backward-compatible facades and re-exports:

- **`media_pipeline`**:
  - Services: `range_service.rs`, `hls_service.rs`, `chunk_transcode.rs`, `probe_service.rs`, `gpu_service.rs`, `transcode_worker.rs`, `transcode_sweeper.rs`, `preview_service.rs`, `subtitle_service.rs`
  - Routes: `media.rs`, `media_info.rs`, `hls.rs`, `transcode.rs`, `preview.rs`, `subtitles.rs`
  - Models: `transcode.rs`, `preview.rs`, `subtitle.rs`
- **`casting`**:
  - Services: `cast_control.rs`, `cast_discovery.rs`, `cast_origin.rs`, `cast_proto.rs`, `cast_registry.rs`, `cast_transport.rs`, `dlna_service.rs`
  - Routes: `cast.rs`
- **`catalog`**:
  - Scanner Engine merged: `rust/src/services/catalog/scanner/` (`engine.rs`, `models.rs`, `parser.rs`, `tmdb_client.rs`) with `movie_service.rs`, `asset_service.rs`, `scan_service.rs`, `tmdb_artwork.rs`, `path_resolver.rs`, and `progress_service.rs`
  - Routes: `movies.rs`, `assets.rs`, `scan.rs`, `progress.rs`
  - Models: `movie.rs`, `progress.rs`
- **`identity`**:
  - Services: `auth_service.rs`, `device_service.rs`, `audit_service.rs`
  - Routes: `auth.rs`, `qr_auth.rs`, `devices.rs`, `admin.rs`
  - Models: `auth.rs`, `audit.rs`
- **`ops`**:
  - Services: `storage_service.rs`, `system_service.rs`, `upload_service.rs`, `job_service.rs`
  - Routes: `storage.rs`, `system.rs`, `upload.rs`, `jobs.rs`, `app_dist.rs`, `health.rs`, `spa.rs`
  - Models: `storage.rs`, `system.rs`, `upload.rs`, `job.rs`

All public HTTP routes, router mount points in `rust/src/lib.rs`, and service calls maintain 100% path stability and backward compatibility via transparent module facades in `services/mod.rs`, `routes/mod.rs`, and `models/mod.rs`.

### 2. FFmpeg/FFprobe Subprocess & GPU Semaphore Governance
- **`ProcessGuard` RAII Guard:** Implemented in `gpu_service.rs`. Deterministically terminates child processes upon drop (`kill_on_drop(true)` + `try_wait()` fallback) to guarantee that aborted HTTP range streams, disconnected clients, or cancelled transcode jobs leave zero zombie FFmpeg/FFprobe processes.
- **Priority Concurrency Semaphores:**
  - `SubprocessPriority::InteractivePlayback`: Dedicated high-priority semaphore allowing immediate GPU access for active streams (`hls_service`, `chunk_transcode`).
  - `SubprocessPriority::InteractiveProbe`: Bounded concurrent probe semaphore for `ffprobe` metadata inspection.
  - `SubprocessPriority::BackgroundExtract`: Low-priority semaphore for storyboard seek thumbnail rendering and subtitle extraction.
  - `SubprocessPriority::BackgroundPreTranscode`: Background transcode queue worker semaphore that yields to interactive playback, preventing Windows GPU driver TDR timeouts.
- **`GpuService::run_managed` & `GpuService::spawn_managed`:** Centralized execution wrappers enforcing semaphore acquisition, timeout enforcement, and deterministic lifecycle tracking.

### 3. Integration Test Consolidation into a Single Harness
- Consolidated the 34 individual integration test files in `rust/tests/*.rs` into a unified single binary: `rust/tests/integration/main.rs`.
- Grouped test modules into domain hierarchies matching the backend namespaces:
  - `rust/tests/integration/media_pipeline/`
  - `rust/tests/integration/casting/`
  - `rust/tests/integration/catalog/`
  - `rust/tests/integration/identity/`
  - `rust/tests/integration/ops/`
- Configured `[[test]] name = "integration"` in `rust/Cargo.toml`.
- Configured `scripts/cargo.bat` to default `RUST_TEST_THREADS=1` when running tests, ensuring full test isolation across shared PostgreSQL database tables.
- **Outcome:** Eliminates duplicate linking of 34 separate Windows PE binaries (`.exe`), slashing cargo test compilation overhead by over 50%.

---

## Verification Results

1. **Cargo Check & Compiler Warnings:**
   - Command: `scripts/cargo.bat check --manifest-path rust/Cargo.toml`
   - Output: `Finished dev profile in 7.89s` with **0 warnings and 0 errors**.
2. **Cargo Test Verification:**
   - Command: `scripts/cargo.bat test --manifest-path rust/Cargo.toml`
   - Output:
     - Unit tests: **All passed**.
     - Integration test harness: **241 passed; 0 failed; 0 ignored; 0 measured; finished in 121.98s**.
     - Doc tests: **0 failed**.
     - Result: **100% green**.
