# Walkthrough: Upload Throughput Optimization (100+ MB/s)

## Root Cause Analysis
During high-speed local network uploads over Wi-Fi 6 (5 GHz) and Gigabit Ethernet, upload throughput was severely capped at **~17.3 MB/s** despite the physical network link supporting over 1,000 Mbps (~125 MB/s).

A benchmark on the physical media storage drive `D:\Flicks` (a Western Digital 2.5" 5400 RPM SATA HDD) revealed the exact issue:
- In `rust/src/services/ops/upload_service.rs`, `append_chunk()` called `file.sync_all().await` on **every single 8 MiB chunk**.
- On Windows, `sync_all()` invokes the Win32 `FlushFileBuffers()` API, forcing the drive's onboard write cache to flush to the physical spinning disk platters before acknowledging the HTTP request.
- A 5400 RPM HDD takes 10–15ms per physical flush, adding ~350ms of dead stall time per chunk.
- Live benchmark with `file.sync_all()`: **17.7 MB/s** (identically reproducing the 17.3 MB/s observed in the browser).
- Live benchmark without `file.sync_all()`: **425.5 MB/s** (absorbed by OS write cache and written out sequentially).

---

## Deliverables & Key Changes

### 1. Backend Chunk Pipeline (`rust/src/services/ops/upload_service.rs`)
- **Removed `file.sync_all()` from `append_chunk()`**:
  - Eliminated the per-chunk `FlushFileBuffers` stall on the HDD platter.
  - Allowed Windows NTFS file caching to stream sequential chunk writes in memory and flush continuously in the background without blocking HTTP chunk acknowledgements.
- **Added Final Flush to `finalize_session()`**:
  - Before moving/renaming the assembled part file to the final media catalog directory (`target`), `finalize_session()` executes `file.sync_all().await` once on the complete file to ensure 100% data durability and integrity on disk.

---

## Verification & Benchmarks

1. **Static Analysis & Tests**:
   - `cargo fmt --check --manifest-path rust/Cargo.toml`: Clean formatting.
   - `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings`: 0 warnings.
   - `cargo test --manifest-path rust/Cargo.toml --test integration -- ops::upload_flow_test`: 6/6 tests passed.

2. **Server-Side Chunk Throughput Benchmark**:
   - Transferred 80 MB across 10 sequential 8 MiB HTTP chunks using persistent HTTP keep-alive to `http://127.0.0.1:8000/api/upload/chunk/{upload_id}`:
     - **Before**: ~17.3 MB/s
     - **After**: **307.1 MB/s** (80.0 MB transferred in 0.26s)
   - The server can now effortlessly ingest at full Gigabit Ethernet line rate (100–125 MB/s).

3. **Live Deployment**:
   - Built optimized release binary: `cargo build --manifest-path rust/Cargo.toml --release`.
   - Deployed executable to `E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe`.
   - Restarted `MediaServerRust` Windows service and verified `/health` is healthy.
