# Implementation Plan — Architectural Tightening Slice 2: Rust Domain Modularization, GPU Governance & Test Consolidation

## 1. Overview & Context
This plan details **Slice 2** of the architectural tightening directive from Argon. The Rust backend currently has flat service (29 modules), route (22 modules), and model directories, uncoordinated FFmpeg/FFprobe subprocess spawns, and 34 individual integration test binaries that incur heavy MSVC linking times on Windows (nearly 3 minutes per build). 

This slice reorganizes the backend into five cohesive domain submodules, unifies FFmpeg/FFprobe process management with deterministic kill-on-drop guards in `gpu_service.rs`, and consolidates integration tests into a single structured integration suite.

Work is performed on the dedicated branch: `feat/argon-architectural-revamp`.

---

## 2. Scope

### A. Domain Submodularization (Zero URL & Contract Drift)
Reorganize `rust/src/services/`, `rust/src/routes/`, and `rust/src/models/` into five domains, maintaining re-export facades in `mod.rs` to guarantee complete backward-compatibility:

1. **`media_pipeline`**:
   - **Services:** `range_service.rs`, `hls_service.rs`, `chunk_transcode.rs`, `probe_service.rs`, `gpu_service.rs`, `transcode_worker.rs`, `transcode_sweeper.rs`, `preview_service.rs`, `subtitle_service.rs`.
   - **Routes:** `media.rs`, `media_info.rs`, `hls.rs`, `transcode.rs`, `preview.rs`, `subtitles.rs`.
   - **Models:** `transcode.rs`, `preview.rs`, `subtitle.rs`.
2. **`casting`**:
   - **Services:** `cast_control.rs`, `cast_discovery.rs`, `cast_origin.rs`, `cast_proto.rs`, `cast_registry.rs`, `cast_transport.rs`, `dlna_service.rs`.
   - **Routes:** `cast.rs`.
   - Models: embedded in services / shared types.
3. **`catalog`**:
   - **Services:** `movie_service.rs`, `asset_service.rs`, `scan_service.rs`, `tmdb_artwork.rs`, `path_resolver.rs`, `progress_service.rs`, and merge `rust/src/scanner/` (`engine.rs`, `models.rs`, `parser.rs`, `tmdb_client.rs`).
   - **Routes:** `movies.rs`, `assets.rs`, `scan.rs`, `progress.rs`.
   - **Models:** `movie.rs`, `progress.rs`.
4. **`identity`**:
   - **Services:** `auth_service.rs`, `device_service.rs`, `audit_service.rs`.
   - **Routes:** `auth.rs`, `qr_auth.rs`, `devices.rs`, `admin.rs`.
   - **Models:** `auth.rs`, `audit.rs`.
5. **`ops`**:
   - **Services:** `storage_service.rs`, `system_service.rs`, `upload_service.rs`, `job_service.rs`.
   - **Routes:** `storage.rs`, `system.rs`, `upload.rs`, `jobs.rs`, `app_dist.rs`, `health.rs`, `spa.rs`.
   - **Models:** `storage.rs`, `system.rs`, `upload.rs`, `job.rs`.

### B. Unify FFmpeg/FFprobe Subprocess & GPU Concurrency Governance
1. In `gpu_service.rs`, introduce `ProcessGuard` wrapping child processes with deterministic kill-on-drop (`Drop` implementation that ensures aborted requests or timeouts terminate FFmpeg trees immediately).
2. Implement `SubprocessPriority` (`InteractivePlayback`, `InteractiveProbe`, `BackgroundExtract`, `BackgroundPreTranscode`) with concurrency semaphore gating to protect Windows hardware adapters from TDR driver resets during concurrent transcodes.
3. Provide managed helpers in `GpuService` for spawning FFmpeg/FFprobe tasks with priority and RAII guard lifecycle tracking.
4. Fix compiler warnings in `cast_control.rs` (duplicate `#[test]` macro attributes).

### C. Consolidate Integration Test Binaries
1. In `rust/tests/`, combine the 32 individual test files into a single consolidated integration harness: `rust/tests/integration/main.rs`.
2. Group the test files as modules under `tests/integration/`:
   - `tests/integration/media_pipeline/`
   - `tests/integration/casting/`
   - `tests/integration/catalog/`
   - `tests/integration/identity/`
   - `tests/integration/ops/`
3. Configure `[[test]]` in `rust/Cargo.toml` with `name = "integration"` and `path = "tests/integration/main.rs"`.
4. Preserve 100% of existing test assertions and test database isolation via `rust/src/test_support.rs`.

---

## 3. Exit Criteria
1. `scripts\cargo.bat test --manifest-path rust/Cargo.toml` compiles and runs cleanly with **0 errors and 0 warnings**.
2. Integration tests compile into a single fast test binary (`integration.exe`) instead of 32 individual binaries.
3. All HTTP endpoints in `rust/src/lib.rs` remain mounted at their exact identical URL patterns with identical request/response payloads.
4. Git working tree is committed with descriptive slice metadata.

---

## 4. Risks & Mitigation
- **Risk:** Compiler errors during module relocation due to internal `crate::services::*` and `crate::routes::*` references.
  - **Mitigation:** The parent `rust/src/services/mod.rs`, `rust/src/routes/mod.rs`, and `rust/src/models/mod.rs` will retain `pub use <domain>::*;` glob re-exports. This ensures internal code and external harnesses resolve symbols transparently.
- **Risk:** Database race conditions in consolidated integration test binary.
  - **Mitigation:** Each test in the suite already invokes `test_support::TestContext::new()` which provisions an isolated, unique PostgreSQL database/schema (`test_db_<uuid>`) per test run, maintaining complete concurrency safety.
- **Risk:** Lingering processes during killed test runs.
  - **Mitigation:** The new `ProcessGuard` in `gpu_service.rs` ensures any child process is terminated when its handle drops.

---

## 5. Open Decisions
- **Decision:** Keep `rust/src/scanner` accessible via `crate::scanner` through a top-level re-export alias (`pub use services::catalog::scanner;`) in `rust/src/lib.rs` so any external tool or script referencing `media_server_api::scanner` experiences zero breakage.
