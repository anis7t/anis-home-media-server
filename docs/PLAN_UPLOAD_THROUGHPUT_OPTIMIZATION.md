# Implementation Plan: Optimize Resumable Upload Throughput to 100+ MB/s

## 1. Problem Statement & Root Cause
On local network uploads over Wi-Fi 6 (5 GHz) and Gigabit Ethernet, upload throughput is strictly capped at **~17.3 MB/s** despite network link capacity exceeding 1 Gbps (125 MB/s).

Live benchmarking on the physical media drive `D:\Flicks` (Western Digital 2.5" 5400 RPM SATA HDD) demonstrated the exact bottleneck:
- **Write with `file.sync_all()` per 8 MiB chunk**: **17.7 MB/s** (Win32 `FlushFileBuffers` forces physical platter flush, stalling I/O).
- **Write without `file.sync_all()` (OS write caching)**: **425.5 MB/s** (OS writes to cache memory and writes out sequentially).

In `rust/src/services/ops/upload_service.rs`, `append_chunk()` invokes `file.sync_all().await` on every single 8 MiB chunk, bottlenecking the entire upload pipeline to the physical head seek and sync latency of the 5400 RPM HDD.

---

## 2. Scope
- **What changes**:
  - **Backend Chunk Appender (`rust/src/services/ops/upload_service.rs`)**:
    - Remove `file.sync_all()` from `append_chunk()`. Allow Windows OS write caching to buffer sequential chunk writes in memory and stream them to disk without artificial pipeline stalls.
  - **Backend Finalizer (`rust/src/services/ops/upload_service.rs`)**:
    - In `finalize_session()`, explicitly invoke `file.sync_all()` once on the fully assembled file before moving/renaming it to the target media directory, ensuring 100% data durability.
  - **Tests (`rust/tests/integration/ops/upload_flow_test.rs`)**:
    - Verify that all chunked upload flow tests (`chunk_flow_enforces_offsets_limits_and_completes`, `abort_removes_temp_files`, `upload_init_enforces_25_gib_cap`) continue to pass.
  - **Deployment**:
    - Build release binary with `cargo build --manifest-path rust/Cargo.toml --release`.
    - Deploy the fresh binary to `E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe`.
    - Restart `MediaServerRust` and verify live service health and upload throughput.

- **What deliberately does not change**:
  - The chunk size (`8 MiB`) remains unchanged.
  - The 25 GiB safety cap remains unchanged.
  - The frontend upload API and resume logic remain untouched.
  - Offset tracking, boundary verification, and conflict detection (`409 Conflict`) remain identical.

---

## 3. Exit Criteria
- [ ] `cargo fmt --check --manifest-path rust/Cargo.toml` passes with zero formatting issues.
- [ ] `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings` passes with zero warnings.
- [ ] `cargo test --manifest-path rust/Cargo.toml --test integration -- ops::upload_flow_test` passes (6/6 tests).
- [ ] `cargo build --manifest-path rust/Cargo.toml --release` compiles without errors.
- [ ] Fresh binary deployed to `E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe`.
- [ ] `MediaServerRust` Windows service restarted and confirmed healthy on port 8000.
- [ ] Live benchmark probe proves chunk upload processing throughput exceeds 100 MB/s.

---

## 4. Risks & Mitigations
- **Crash Durability During Active Upload**:
  - *Risk*: Without syncing every 8 MiB chunk, an abrupt system power loss during an active upload could leave the most recent in-memory chunk uncommitted to the physical platter.
  - *Mitigation*: The resumable upload protocol already tracks offsets defensively. If an upload is interrupted, the client queries `GET /api/upload/chunk/{upload_id}`, gets the actual uncorrupted byte length from disk, and resumes seamlessly. Final durability is guaranteed by syncing in `finalize_session()`.

---

## 5. Open Decisions
- **Sync at Finalize**: We will perform `file.sync_all()` once upon upload completion in `finalize_session()`, providing full data integrity before the movie is moved into the library catalog.
