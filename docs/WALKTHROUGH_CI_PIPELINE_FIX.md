# Walkthrough: Resolution of GitHub Actions CI Pipeline Failures

**Date:** 2026-10-29  
**Branch:** `android/antigravity-work`  
**GitHub Actions Run:** [40904256389](https://github.com/anis7t/anis-home-media-server/actions/runs/40904256389)  
**Status:** 100% Green (Rust Backend & React 19 Frontend)

---

## 1. Problem Overview & Root Cause Analysis

Following the recent introduction of the production CI workflow in `.github/workflows/ci.yml`, the pipeline encountered failures across three consecutive stages:

1. **Docker PostgreSQL Health Check Failure**:
   - The workflow used `options: >- --health-cmd pg_isready ...`.
   - In Alpine PostgreSQL, `pg_isready` defaults to the current OS user (`root`), causing repeated `FATAL: role "root" does not exist` connection attempts in the runner logs until container initialization finished.

2. **Clippy Static Analysis Failures (`-D warnings`)**:
   - The backend job ran `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings`.
   - The compiler threw 40 warnings across the library crate (`media-server-api`) and 13 warnings across integration tests. Under `-D warnings`, every warning became a hard fatal error terminating the job with exit code 101.

3. **Missing Ephemeral Test Fixtures for Backend Integration Tests**:
   - Once formatting and Clippy passed, 237 of 242 tests succeeded, but 5 tests failed with HTTP 404:
     - `ops::spa_serving_test::test_serves_spa_index_at_root`
     - `ops::spa_serving_test::test_client_side_routing_fallback`
     - `ops::app_dist_test::test_app_update_production_manifest`
     - `ops::app_dist_test::test_app_download_production_full_apk`
     - `ops::app_dist_test::test_app_download_production_range_request`
   - Cause: `web/dist` and `updates/production/*` are gitignored. In the clean CI checkout on `ubuntu-latest`, neither the built SPA nor the Android client APK existed on disk.

---

## 2. Changes Made & Deliverables

### A. CI Workflow Hardening ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml))
1. **PostgreSQL Health Check**:
   - Changed `--health-cmd pg_isready` to `--health-cmd "pg_isready -U postgres"`.
2. **Environment Path Pinning**:
   - Added `MEDIA_SERVER_BASE_DIR: ${{ github.workspace }}` and `MEDIA_SERVER_STATIC_DIR: ${{ github.workspace }}/web/dist`.
3. **Comprehensive Synthetic Fixture Generation**:
   - Expanded the pre-test fixture setup step to synthesize:
     - **Media**: 1-second H.264/AAC synthetic test video via `ffmpeg`.
     - **SPA**: Ephemeral `web/dist/index.html` with `<div id="root"></div>` and `web/dist/assets/test.js` to satisfy Axum SPA routing and immutable cache tests.
     - **App Distribution**: Ephemeral `updates/production/manifest.json` and zero-padded 11MB `media-server-client.apk` to satisfy APK download, byte-range streaming, and manifest update tests.

### B. Rust Clippy & Formatting Fixes ([`rust/src/`](../rust/src/) & [`rust/tests/`](../rust/tests/))
- **`src/services/media_pipeline/gpu_service.rs`**: Replaced verbose `std::io::Error::new(ErrorKind::Other, ...)` with `std::io::Error::other(...)`.
- **`src/routes/casting/cast.rs`**: Consolidated identical `1.0` branches in mute truthiness checks (`if raw.is_null() || truthy(&raw)`).
- **`src/services/ops/upload_service.rs`**, **`src/routes/media_pipeline/preview.rs`**, **`src/routes/media_pipeline/subtitles.rs`**, **`src/services/catalog/path_resolver.rs`**, **`src/services/catalog/scanner/tmdb_client.rs`**: Replaced closure pattern matchers with character arrays (e.g. `['/', '\\']`, `['t', 'T']`, `['.', ' ']`).
- **`src/services/catalog/movie_service.rs`**: Used `sort_by_key(|a| std::cmp::Reverse(a.year))` and `sort_by_key(|a| a.title.to_lowercase())`.
- **`src/services/ops/system_service.rs`**: Implemented `Default for SystemService`.
- **`src/services/media_pipeline/transcode_worker.rs`**: Replaced `map_or` with `is_some_and`, used `.lines().rfind(...)`.
- **`src/services/identity/device_service.rs`**: Simplified redundant pattern match guard to `""`.
- **`src/services/media_pipeline/chunk_transcode.rs`**: Used `matches!` macro on metadata probing fallback.
- **`src/services/identity/auth_service.rs`**: Used `.replace([';', '\n'], ",")` and `.div_ceil(3)`.
- **`src/services/media_pipeline/probe_service.rs`**: Removed redundant `..Default::default()` on fully initialized struct.
- **`src/services/catalog/tmdb_artwork.rs`**: Converted `&PathBuf` parameter to `&Path` slice and imported `std::path::Path`.
- **`rust/tests/integration/`**: Fixed `cloned_ref_to_slice_refs`, `needless_range_loop` with `.enumerate()`, `manual_is_multiple_of`, `field_reassign_with_default`, and boolean assert comparisons across `job_queue_test.rs`, `subtitles_test.rs`, `chunk_transcode_test.rs`, and `hls_transcode_test.rs`.
- Target-scoped `#[allow(clippy::too_many_arguments)]`, `#[allow(clippy::type_complexity)]`, and `#[allow(clippy::result_unit_err)]` on existing signatures to maintain strict API parity.

---

## 3. Verification & CI Run Results

### Local Verification
```bash
cargo fmt --check --manifest-path rust/Cargo.toml
# Exited 0 (Clean)

cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
# Exited 0 (Zero warnings across lib, bins, and tests)
```

### GitHub Actions CI Workflow Run: [40904256389](https://github.com/anis7t/anis-home-media-server/actions/runs/40904256389)
- **Commit:** `e7cc554` on `android/antigravity-work`
- **React 19 Frontend (SPA):** ✓ Success in 1m 50s
  - `npm ci`
  - `npm run typecheck`
  - `npm run lint` (oxlint)
  - `npm run test` (Vitest)
  - `npm run build` (Vite production bundle)
- **Rust Backend (Axum):** ✓ Success in 4m 9s
  - PostgreSQL 17 health check passed instantly with `-U postgres`
  - `cargo fmt --check` passed
  - `cargo clippy --all-targets -- -D warnings` passed with 0 warnings
  - Synthetic test fixtures generated
  - **242 / 242 tests passed (0 failed, 0 ignored)**
- **Overall Pipeline Status:** **100% Green (PASS)**
