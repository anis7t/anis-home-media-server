# Implementation Plan: Increase Upload Limit from 20 GiB to 25 GiB

## 1. Scope
- **What changes**:
  - **Backend (`rust/src/services/ops/upload_service.rs`)**: Update `MAX_UPLOAD_BYTES` from `20 * 1024 * 1024 * 1024` (20 GiB) to `25 * 1024 * 1024 * 1024` (25 GiB). Update associated documentation comments.
  - **Backend Route (`rust/src/routes/ops/upload.rs`)**: Update header comments to reflect the 25 GiB total cap (the dynamic error string already formats `uploads::MAX_UPLOAD_BYTES / (1024 * 1024 * 1024)` GiB).
  - **Frontend Constants & API Client (`web/src/features/upload/uploadApi.ts`)**: Update `MAX_UPLOAD_BYTES` constant to `25 * 1024 * 1024 * 1024` and update the local rejection error message from `The selected file exceeds the 20 GiB limit.` to `The selected file exceeds the 25 GiB limit.`.
  - **Frontend Upload Hook (`web/src/features/upload/useMediaUpload.ts`)**: Update client-side validation error message to reference the 25 GiB limit.
  - **Frontend Upload Modal (`web/src/features/upload/MediaUploadModal.tsx`)**: Update UI validation error string and instructional subtext to reflect `Resumable 8 MiB chunks · up to 25 GiB`.
  - **Frontend Tests (`web/src/features/upload/uploadApi.test.ts`)**: Add explicit boundary assertions verifying files up to 25 GiB are accepted while files exceeding 25 GiB are rejected.
  - **API Schema & Documentation (`web/src/lib/api/schema.ts`, `docs/openapi.yaml`, `docs/MANUAL.md`)**: Synchronize references to the maximum upload cap from 20 GiB to 25 GiB.
  - **Production Deployment**: Compile the release binary and frontend build, then restart `MediaServerRust` so the running Axum service accepts 25 GiB uploads immediately.

- **What deliberately does not change**:
  - The chunk size (`8 MiB`) remains unchanged. Resumable chunked upload protocol semantics, offset tracking, integrity verification, and directory staging remain untouched.
  - Allowed file formats (`.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`) remain identical.
  - Single unchunked upload limit (`SINGLE_UPLOAD_MAX = 50 MiB`) remains intact for small assets.
  - Database schema and storage drive layouts remain unchanged.

## 2. Exit Criteria
- [ ] `cargo test --manifest-path rust/Cargo.toml -- --test-threads=1` passes cleanly with zero regressions.
- [ ] `npm --prefix web run test` passes, including upload boundary validation tests.
- [ ] `npm --prefix web run typecheck` passes with zero TypeScript diagnostic errors.
- [ ] `npm --prefix web run build` builds the production distribution cleanly to `web/dist/`.
- [ ] `cargo build --manifest-path rust/Cargo.toml --release` compiles without warnings or errors.
- [ ] `MediaServerRust` Windows service restarted and confirmed healthy on port 8000.
- [ ] Verified via probe that the backend `/api/upload/chunk/init` accepts requests for file sizes between 20 GiB and 25 GiB (e.g. 24 GiB), and rejects files > 25 GiB with HTTP 413 Payload Too Large.

## 3. Risks & Mitigations
- **Disk Space Exhaustion on Temporary Drive**:
  - *Risk*: A 24–25 GiB upload requires equivalent temporary staging storage (`upload_tmp` on `D:\Flicks\.uploads` or `E:\MediaServer\cache\uploads`) before final assembly.
  - *Mitigation*: Both `D:` and `E:` have ample storage capacity, and chunk cleanup routines prune stale uploads older than 24 hours.
- **Client-Side Timeout During Chunk Transfers**:
  - *Risk*: Slower network connections could experience longer overall upload durations.
  - *Mitigation*: Uploads use 8 MiB discrete chunks with individual timeouts and automatic resume on failure/reconnect, preventing large monolithic request timeouts.

## 4. Open Decisions
- **Binary vs Decimal Gigabytes**: Standard practice in this codebase is binary gigabytes (`GiB`, \(1024^3\) bytes = \(26,843,545,600\) bytes). A 24 GB movie (whether \(24 \times 10^9\) bytes or \(24 \times 1024^3\) bytes) will easily pass within the 25 GiB limit.
- **Service Restart**: Requires restarting the `MediaServerRust` service via PowerShell to apply backend changes to live users.
