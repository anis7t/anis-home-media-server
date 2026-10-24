# Phase 5E Walkthrough: Native Rust HLS Delivery, Transcoded MP4 Serving & Concurrency Benchmarking

> **Document Type:** Sliced Migration Walkthrough  
> **Repository:** `anis7t/media-server`  
> **Branch:** `feat/rust-api-foundation`  
> **Governing Document:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 5 & §Phase 6  
> **Status:** ✅ **DELIVERED, VERIFIED & PASSING**

---

## 1. Executive Summary

Phase 5E is the final capstone slice of **Phase 5: Media Library, Playback, and Streaming**. It delivers native Rust high-performance HLS master playlist delivery, transport stream (`.ts`) and fragmented MP4 (`.m4s`, `init.mp4`) chunk segment delivery, transcoded MP4 cache streaming, dynamic RFC 8216 target duration healing, and end-to-end streaming concurrency benchmarks.

With Phase 5E delivered:
- **Rust Test Suite**: **47 passing integration tests** across 6 test suites with **0 failures and 0 warnings**.
- **Real Host Streaming**: Validated against live movies in `D:\Flicks` and active HLS caches in `E:\MediaServer\cache\hls`.
- **Peak Concurrency Performance**: Reached **510.86 Mbps aggregate throughput** across 16 concurrent direct streams with **100% success rate**, while maintaining an exceptionally small memory footprint of only **32.5 MB RSS** (vs Python Waitress's 80–95 MB RSS).
- **Phase 5 Milestone**: **Phase 5 is now 100% complete across all 5 sub-phases (5A through 5E)**.

---

## 2. Key Changes & Deliverables

### 2.1 HLS Cache Resolution & Manifest Healing Service ([`rust/src/services/hls_service.rs`](../rust/src/services/hls_service.rs))
- **`get_hls_candidates(path, roots)`**: Computes deterministic SHA-256 hash sets matching Python `transcode_service.py`:
  - `hls:{path}:{size}:{mtime_ns}` (stripping `\\?\` verbatim prefixes).
  - Relative path cross-root variants (`root / rel`, `root / rel_clean`, `root / .archive / rel_clean`).
  - Fallback key: `hls:{filename}:{size}`.
- **`find_hls_dir(path, roots, cache_dir)`**: Evaluates candidate directories on disk, prioritizing:
  1. Completed playlist containing `#EXT-X-ENDLIST`.
  2. In-progress directory with highest segment/chunk progress.
  3. Primary candidate directory.
- **`honest_target_duration(manifest)`**: Dynamically extracts `#EXTINF:<duration>` labels across all segments and computes `ceil(max(durations))`. If `#EXT-X-TARGETDURATION:N` is missing or below the ceiling, raises the declaration to ensure RFC 8216 compliance and eliminate playback timeline drift.
- **`is_valid_segment_name(segment)`**: Zero-allocation validator matching `init.mp4` and `segment_\d{6}\.(ts|m4s)`.
- **`get_transcode_cache_path(path, mode, cache_dir)`**: Deterministic cache file path lookup for transcoded MP4s in `cache/transcodes/{sha256}.mp4`.

### 2.2 HLS & Transcode Route Handlers ([`rust/src/routes/hls.rs`](../rust/src/routes/hls.rs), [`rust/src/routes/transcode.rs`](../rust/src/routes/transcode.rs))
- **`GET /hls/{*path}`**:
  - `playlist.m3u8`: Reads master playlist, applies `honest_target_duration`, serves with `application/vnd.apple.mpegurl` and `Cache-Control: no-cache, max-age=0`. Returns HTTP 503 `Retry-After: 1` when transcoding is in flight without segments.
  - Segment delivery (`segment_\d{6}.(ts|m4s)`, `init.mp4`): Streams via `RangeService` with `video/mp2t` or `video/mp4`, `Cache-Control: public, max-age=3600`, and full CORS headers.
  - Preflight `OPTIONS`: Returns HTTP 200 with `Access-Control-Allow-Origin: *` and CORS methods.
- **`GET /transcode/{*path}`**:
  - Direct / compat MP4 cache streaming: Resolves transcoded file and streams with RFC 7233 byte-range support. Returns HTTP 503 `Retry-After: 2` if transcode is in flight.
- **`GET /api/transcode-status/{*filename}`**:
  - Returns live transcode status: `complete` (with `progress: 100.0`, `is_complete: true`) if `#EXT-X-ENDLIST` or cached MP4 exists, `transcoding` if in flight, or `idle`.

### 2.3 Router Integration ([`rust/src/lib.rs`](../rust/src/lib.rs))
- Mounted `hls_routes` (`/hls/{*path}`) and `transcode_routes` (`/transcode/{*filename}`, `/api/transcode-status/{*filename}`) with shared `roots` and `cache_dir`.

### 2.4 Integration Test Suite ([`rust/tests/hls_transcode_test.rs`](../rust/tests/hls_transcode_test.rs))
10 comprehensive integration tests:
1. `test_honest_target_duration_adjustment`: Asserts ceiling calculation and target duration elevation.
2. `test_is_valid_segment_name`: Asserts format acceptance and directory traversal rejection.
3. `test_hls_playlist_delivery_200_and_cors`: Tests manifest delivery with 200 OK, MIME type, and CORS headers.
4. `test_hls_playlist_in_flight_503_retry`: Asserts 503 retry response with `Retry-After: 1`.
5. `test_hls_segment_delivery_ts_and_range`: Asserts `.ts` segment delivery, `video/mp2t`, and 206 partial content.
6. `test_hls_segment_delivery_m4s_and_init`: Asserts `.m4s` and `init.mp4` delivery with `video/mp4`.
7. `test_hls_segment_traversal_and_invalid_names_404`: Asserts 404 on invalid segment names or traversal attempts.
8. `test_transcode_cached_mp4_delivery`: Asserts 200 OK and 206 byte-range delivery for cached transcodes.
9. `test_transcode_uncached_returns_503_and_idle_status`: Asserts 503 on un-cached files and idle status.
10. `test_hls_and_transcode_options_cors`: Asserts CORS preflight support on all routes.

---

## 3. Streaming Concurrency Benchmark Results

Evaluated using [`scripts/benchmark_streaming.py`](../scripts/benchmark_streaming.py) against live video in `D:\Flicks` across 1, 2, 4, 8, and 16 concurrent clients:

| Concurrency | Success Rate | TTFB Latency (p50) | TTFB Latency (p95) | Aggregate Throughput | Avg Throughput / Client | Server RSS Memory |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **1 client** | **100.0%** (1/1) | 48.5 ms | 48.5 ms | **28.03 Mbps** | 28.04 Mbps | 29.2 MB |
| **2 clients** | **100.0%** (2/2) | 127.8 ms | 148.3 ms | **156.29 Mbps** | 83.03 Mbps | 29.2 MB |
| **4 clients** | **100.0%** (4/4) | 134.1 ms | 152.9 ms | **253.85 Mbps** | 76.31 Mbps | 29.8 MB |
| **8 clients** | **100.0%** (8/8) | 302.8 ms | 432.5 ms | **323.67 Mbps** | 56.37 Mbps | 30.2 MB |
| **16 clients** | **100.0%** (16/16) | 317.1 ms | 537.9 ms | **510.86 Mbps** | 39.60 Mbps | **32.5 MB** |

### Benchmark Highlights:
- **Throughput Supremacy**: Native Rust Axum achieved **510.86 Mbps peak aggregate throughput**, outperforming Waitress WSGI (447.88 Mbps) under identical 16-client load.
- **Resource Efficiency**: Maintained a memory footprint of just **32.5 MB RSS**, representing a **~65% reduction in memory overhead** compared to Python Waitress (80–95 MB RSS).
- **100% Zero-Loss Reliability**: Zero failed sessions, zero dropped connections, and monotonic byte streaming across all concurrency tiers.

---

## 4. Phase 5 Complete Slices Summary

With Phase 5E complete, all Phase 5 capabilities are delivered in the native Rust engine:

| Sub-Phase | Focus Area | Routes / Deliverables | Passing Tests | Status |
|---|---|---|:---:|:---:|
| **Phase 5A** | Watch Progress & History | `GET /api/progress`, `POST /api/progress` | 1 | ✅ Commit `d5d469a` |
| **Phase 5B** | RFC 7233 Direct Play | `GET /media/{*path}`, `HEAD /media/{*path}` | 11 | ✅ Commit `62000ce` |
| **Phase 5C** | Subtitles & WebVTT Engine | `GET /subtitles/{*path}`, `GET /api/subtitles/{*filename}` | 12 | ✅ Commit `ea68bd3` |
| **Phase 5D** | Seek-Hover Frame Previews | `GET /api/seek-preview-meta`, `GET /seek-preview`, `GET /preview-vtt` | 9 | ✅ Commit `54b3a63` |
| **Phase 5E** | HLS Delivery & Transcoding | `GET /hls/{*path}`, `GET /transcode/{*path}`, `GET /api/transcode-status` | 10 | ✅ Verified |
| **Foundation** | API Contracts & Health | `/health`, `/api/health`, `/api/system-status`, `/api/movies` | 4 | ✅ Verified |
| **TOTAL** | **Phase 4 & Phase 5 Engine** | **Full Rust Media & Streaming Engine** | **47 / 47** | **100% COMPLETE** |

---

## 5. Next Steps

1. **Commit Phase 5E Deliverables** to branch `feat/rust-api-foundation`:
   - Code files: `rust/src/models/transcode.rs`, `rust/src/services/hls_service.rs`, `rust/src/routes/hls.rs`, `rust/src/routes/transcode.rs`, `rust/src/lib.rs`, `rust/tests/hls_transcode_test.rs`, `scripts/benchmark_streaming.py`.
   - Docs: `docs/PHASE_5E_TRANSCODING_PLAN.md`, `docs/PHASE_5E_TRANSCODING_WALKTHROUGH.md`, `docs/MIGRATION_STATUS.md`.
2. **Proceed to Phase 6 (Rust Transcoding Worker / Multi-GPU Orchestrator)** or Phase 2 (React Web Frontend) per user direction.
