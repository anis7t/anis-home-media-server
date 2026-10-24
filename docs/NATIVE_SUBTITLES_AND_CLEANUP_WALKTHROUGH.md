# Walkthrough: Native Rust Subtitles Engine & Catalog Test Artifacts Purge

## 1. Overview
In this iteration, two critical objectives were fully achieved:
1. **100% Native Rust Subtitle Engine**:
   Rather than proxying requests to Flask, the Rust backend now natively handles the entire subtitle lifecycle:
   - **Embedded Container Subtitles**: Probes container tracks via `ffprobe` and extracts them on-demand via `ffmpeg` directly into cached WebVTT.
   - **OpenSubtitles Online Downloads**: Computes the 64-bit unsigned little-endian word wrapping file hash, queries the OpenSubtitles REST API, streams the `.gz` payload, decompresses it via `flate2::read::GzDecoder`, normalizes it to WebVTT, and caches it atomically.
   - **Local Sidecar Subtitles**: Discovers local `.srt` and `.vtt` sidecars across media roots, converts them with time offset shifting (`?offset=<seconds>`), and auto-detects language scripts.
   - **Multipart Subtitle Uploads**: Allows users to upload custom `.srt` and `.vtt` subtitles directly to the server with content-based language auto-detection.
2. **Catalog Test Artifacts Purge & Future Pollution Prevention**:
   - Identified the source of phantom test movies (`ManageTest`, `TestActiveMovie`, `Upload Test Movie`, `Rich Movie`, `Mock.mkv`, and `rust_test_movie_200-205`): legacy integration tests and preview test harnesses that inserted rows without teardown fixtures.
   - Verified that zero dummy video files exist on physical disk (`D:\Flicks`).
   - Safely purged all 11 phantom rows from both **PostgreSQL** (`media_server`) and **SQLite** (`media.db`).
   - Hardened `rust/tests/preview_test.rs` with automatic cleanup in `setup_preview_test()` and explicit `harness.teardown().await` across all async tests.

---

## 2. Key Architecture & Code Changes

### A. Subtitle Models & Service (`rust/src/models/subtitle.rs`, `rust/src/services/subtitle_service.rs`)
- Added `EmbeddedSubtitleStream` for ffprobe JSON deserialization.
- Implemented `compute_opensubtitles_hash` with 64-bit unsigned little-endian word wrapping over the first and last 64 KB of the media file.
- Implemented `probe_embedded_subtitles` to discover container tracks (`subrip`, `webvtt`, `mov_text`, `ass`, `ssa`, `text`).
- Implemented `extract_embedded_subtitle` with atomic caching at `cache/subtitles/embedded/{hash}_{idx}.vtt`.
- Implemented `fetch_online_subtitle` with atomic caching at `cache/subtitles/online/{hash}.vtt`.
- Normalized paths before SHA256 cache key hashing by stripping Windows `\\?\` extended prefix, ensuring byte-for-byte cache key parity with Python and disk caches.

### B. Route Prefix Dispatcher (`rust/src/routes/subtitles.rs`, `rust/src/lib.rs`)
- Solved Axum's radix tree matchit conflict by routing all subtitle streams through `/subtitles/{*path}` and using an internal prefix dispatcher:
  - `embedded/*` -> `extract_embedded_subtitle`
  - `online/*` -> `fetch_online_subtitle`
  - default -> local sidecars
- Added full CORS headers (`Access-Control-Allow-Origin: *`, `Accept-Ranges: bytes`) and `Content-Type: text/vtt; charset=utf-8` to ensure seamless video player cue rendering.

### C. Recursive PathResolver Fallback (`rust/src/services/path_resolver.rs`)
- Added `find_in_dir` recursive search fallback to `PathResolver::resolve_media_path`.
- When database records or clients reference movies by bare filename rather than full relative path, `PathResolver` searches subdirectories across configured media roots (preserving directory traversal defenses and sandbox boundaries).

### D. Test Artifact Prevention (`rust/tests/preview_test.rs`)
- Added pre-test bulk cleanup `DELETE FROM movies/progress WHERE filename LIKE 'rust_test_movie_%'` to `setup_preview_test()`.
- Added explicit `harness.teardown().await` across all 9 async tests to ensure zero test records linger after test completion.

---

## 3. Verification & Results

### 1. Catalog Cleanliness Verification
- **PostgreSQL Database**: Exactly **39 genuine library movies** (0 test artifacts).
- **SQLite Database**: Synchronized with 39 genuine library movies.
- **REST API (`GET /api/movies`)**: Returned `total: 39`, zero test titles.

### 2. Live Subtitle Delivery Verification (Port 8001)
| Subtitle Type | Sample Movie | Track ID | HTTP Status | Content-Type | Verification Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Online (OpenSubtitles)** | *2001: A Space Odyssey* | `online:en` | `200 OK` | `text/vtt; charset=utf-8` | Valid WebVTT dialog streamed |
| **Embedded (MKV)** | *Alien 3* | `embed:2` | `200 OK` | `text/vtt; charset=utf-8` | Stream 2 extracted & streamed |
| **Local Sidecar** | *Monsters, Inc.* | `dir:Monsters...srt` | `200 OK` | `text/vtt; charset=utf-8` | Local SRT normalized to VTT |

### 3. Rust Test Suite
- `scripts/cargo.bat test --test subtitles_test`: **16/16 passed** (including hash calculation, offset shifting, embedded/online cached serving, and multipart upload).
- `scripts/cargo.bat test --test preview_test`: **9/9 passed** with zero lingering test rows in PostgreSQL.
- `scripts/cargo.bat test --test streaming_range_test`: **11/11 passed**.
- Total Rust test suite: **61/61 tests passing**.
