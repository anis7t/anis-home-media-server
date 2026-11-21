# Walkthrough: Media Upload Limit Increased to 25 GiB

## Executive Summary
The media upload cap has been increased from 20 GiB to 25 GiB across the Rust backend, React frontend SPA, unit/integration test suites, and API schemas. The change accommodates large 4K / high-bitrate media files (such as 24 GB movies) while preserving resumable 8 MiB chunk streaming, integrity tracking, and client-side validation.

The live production backend binary was recompiled in release mode, the React SPA assets were built, and the `MediaServerRust` Windows service was restarted and verified healthy.

---

## Deliverables & Key Changes

### 1. Rust Backend
- **`rust/src/services/ops/upload_service.rs`**:
  - Updated `MAX_UPLOAD_BYTES` from `20 * 1024 * 1024 * 1024` to `25 * 1024 * 1024 * 1024` (25 GiB).
  - Updated associated doc comments to document the 25 GiB resumable limit.
- **`rust/src/routes/ops/upload.rs`**:
  - Updated route doc comment for chunked uploads to 25 GiB total.
  - The dynamic error handler formatting (`uploads::MAX_UPLOAD_BYTES / (1024 * 1024 * 1024)`) automatically formats `"Upload exceeds the 25 GiB cap"`.
- **`rust/tests/integration/ops/upload_flow_test.rs`**:
  - Added `upload_init_enforces_25_gib_cap()` test asserting that a 25 GiB file initializes successfully (HTTP 200 OK) while a file size of 25 GiB + 1 byte is rejected with HTTP 413 Payload Too Large.

### 2. React 19 Frontend SPA
- **`web/src/features/upload/uploadApi.ts`**:
  - Updated `MAX_UPLOAD_BYTES` constant to `25 * 1024 * 1024 * 1024`.
  - Updated pre-flight error rejection string to `'The selected file exceeds the 25 GiB limit.'`.
- **`web/src/features/upload/useMediaUpload.ts`**:
  - Updated file size guard error message to `'The selected file exceeds the 25 GiB limit.'`.
- **`web/src/features/upload/MediaUploadModal.tsx`**:
  - Updated file picker validation error message to `'The selected file exceeds the 25 GiB limit.'`.
  - Updated modal header subtext to `'Resumable 8 MiB chunks · up to 25 GiB'`.
- **`web/src/features/upload/uploadApi.test.ts`**:
  - Added unit test asserting files exceeding 25 GiB are rejected before network requests with a 413 `UploadApiError`.
  - Added unit test asserting 24 GiB files within the 25 GiB cap successfully initialize chunked upload sessions.

### 3. API Schemas & Documentation
- **`web/src/lib/api/schema.ts`**:
  - Updated OpenAPI TypeScript definitions to document 25 GiB upload caps on `/api/upload/chunk/init`.
- **`docs/openapi.yaml`**:
  - Updated OpenAPI specification endpoint descriptions and 413 error descriptions to 25 GiB.
- **`docs/MANUAL.md`**:
  - Updated user-facing media upload guidelines: `"Drag and drop or choose a .mp4, .mkv, .webm, .mov, .avi, or .m4v file up to 25 GiB."`.

---

## Verification & Test Results

### 1. Frontend Test Suite
- Executed `npm --prefix web run test`:
  - 46 test files passed (338 tests passed, including `uploadApi.test.ts`).
- Executed `npm --prefix web run typecheck`:
  - `tsc -b` completed with 0 errors.
- Executed `npm --prefix web run lint`:
  - `oxlint` completed with 0 errors.
- Executed `npm --prefix web run build`:
  - Production build succeeded with all bundles compiled into `web/dist/`.

### 2. Rust Backend Verification
- Executed `cargo fmt --check --manifest-path rust/Cargo.toml`:
  - Clean, 0 formatting issues.
- Executed `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings`:
  - Clean, 0 warnings.
- Executed `cargo test --manifest-path rust/Cargo.toml --test integration -- ops::upload_flow_test`:
  - 6/6 tests passed including the new `upload_init_enforces_25_gib_cap` test.
- Executed `cargo build --manifest-path rust/Cargo.toml --release`:
  - Successfully built optimized release binary in `rust/target/release/`.

### 3. Live Service Deployment & Health Verification
- Executed `Restart-Service MediaServerRust`.
- Verified service state:
  ```powershell
  Status   Name               DisplayName
  ------   ----               -----------
  Running  MediaServerRust    Media Server API (Rust/Axum)
  ```
- Polled `/health` endpoint:
  ```json
  {"engine":"rust","service":"media-server-api","status":"healthy","version":"0.1.0"}
  ```
- Verified live upload initialization requires admin credentials and is active.
