# Phase 5D: Seek-Hover Frame Previews Engine — Walkthrough

**Branch:** `feat/rust-api-foundation`  
**Date:** 2026-10-15  
**Engine:** Rust (Axum 0.8 + Tokio 1.x + `sha2` + `hex` + Tokio Process Async FFmpeg)  
**Status:** ✅ Complete & Verified (37/37 Total Tests Passing, 9/9 Preview Tests, 0 Compiler Warnings)

---

## 1. Executive Summary

Phase 5D delivers the native Rust seek-hover frame previews engine for `media-server-api` on branch `feat/rust-api-foundation`.

It implements:
- Instant duration and sampling metadata calculation via `GET /api/seek-preview-meta/{*filename}` (querying PostgreSQL `progress`/`movies` first for <1ms responses, with asynchronous `ffprobe` fallback).
- Dynamic interval scaling: 5.0s for short videos (<30m), 10.0s for medium videos (<2h), and 15.0s for feature films (>=2h).
- High-performance on-demand frame extraction via `GET /seek-preview/{*path}` with SHA-256 persistent disk caching matching Python/Flask preview cache conventions (`E:\MediaServer\cache\previews`), allowing 100% instant reuse of pre-existing cached thumbnails.
- WebVTT seek-preview storyboard generator (`GET /preview-vtt/{*filename}`) enabling native seekbar scrubbing previews in HLS.js, Video.js, and mobile clients.
- Traversal protection, out-of-bounds index clamping, and zero console signal broadcasting on Windows.

---

## 2. Implemented Architecture & Deliverables

### A. Preview Models ([`rust/src/models/preview.rs`](file:///e:/MediaServer/rust/src/models/preview.rs))
- `SeekPreviewMetaResponse`:
  - `duration: f64` (media duration in seconds)
  - `interval: f64` (thumbnail interval in seconds: 5.0, 10.0, or 15.0)
  - `count: u64` (total thumbnails: `max(1, ((duration - 0.001) / interval) + 1)`)
  - `base_url: String` (e.g. `/seek-preview/{filename}`)

### B. High-Performance Preview Service ([`rust/src/services/preview_service.rs`](file:///e:/MediaServer/rust/src/services/preview_service.rs))
- **Deterministic SHA-256 Cache Key & Candidate Discovery (`get_preview_key`, `get_preview_dir`):**
  - Generates signatures matching Flask: `preview:{path}:{size}:{mtime_ns}`.
  - Normalizes Windows `\\?\` verbatim prefixes.
  - Discovers existing directories across secondary storage roots and `.archive` paths.
  - Automatically reuses directories containing pre-extracted `.jpg` frames.
- **Duration Fast Path (`get_duration`):**
  - Queries PostgreSQL `progress` table for exact duration in seconds.
  - Queries PostgreSQL `movies` table for `runtime` in minutes (`runtime * 60.0`).
  - Falls back to `ffprobe` container format duration if not in database.
- **On-Demand Asynchronous FFmpeg Extraction (`ensure_thumbnail`):**
  - Checks if `thumb_{index:05d}.jpg` exists in cache directory; returns instantly if cached.
  - Clamps seek timestamp: `min((duration - 0.05).max(0.0), index as f64 * interval)`.
  - Spawns asynchronous non-blocking Tokio process:
    `ffmpeg -hide_banner -loglevel error -ss {timestamp:.3f} -i {video_path} -frames:v 1 -vf scale=320:-2 -q:v 5 -y {part_file}`.
  - Atomically moves part file to final `thumb_{index:05d}.jpg`.
- **WebVTT Storyboard Generator (`generate_storyboard_vtt`):**
  - Builds standard WebVTT cue list linking timestamp intervals to thumbnail URLs:
    ```text
    WEBVTT

    00:00:00.000 --> 00:00:15.000
    /seek-preview/sample.mp4/thumb_00000.jpg
    ```

### C. Preview HTTP Routes ([`rust/src/routes/preview.rs`](file:///e:/MediaServer/rust/src/routes/preview.rs))
- `GET /api/seek-preview-meta/{*filename}`: Returns preview sampling metadata JSON.
- `GET /seek-preview/{*path}`: Serves individual thumbnail JPEG frames with HTTP 200, `image/jpeg`, `Cache-Control: public, max-age=86400`, `Accept-Ranges: bytes`, and CORS headers. Supports `HEAD` and `OPTIONS`.
- `GET /preview-vtt/{*filename}`: Serves WebVTT seek storyboard with `text/vtt; charset=utf-8` and CORS headers.

### D. App Router Integration ([`rust/src/lib.rs`](file:///e:/MediaServer/rust/src/lib.rs))
- Updated `create_app` signature to receive `cache_dir: PathBuf`.
- Instantiated shared `PreviewState` (`pool`, `media_roots`, `cache_dir`).
- Mounted preview routes on main Axum router.

---

## 3. Test Verification & Results

All 37 tests across all 5 integration test suites pass with 0 errors and 0 compiler warnings.

### Full Test Suite Results (`cargo test`)

```text
running 4 tests (tests\api_contracts_test.rs)
test test_health_endpoints ... ok
test test_system_status_endpoint ... ok
test test_movies_list_endpoint ... ok
test test_movie_details_endpoint ... ok
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.35s

running 9 tests (tests\preview_test.rs)
test test_preview_meta_calculation ... ok
test test_preview_key_determinism ... ok
test test_generate_storyboard_vtt ... ok
test test_preview_traversal_denied ... ok
test test_invalid_thumbnail_name_404 ... ok
test test_get_preview_meta_endpoint ... ok
test test_get_preview_vtt_storyboard ... ok
test test_get_preview_thumb_cached_serving ... ok
test test_preview_thumb_head_and_options ... ok
test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.50s

running 1 test (tests\progress_contracts_test.rs)
test test_progress_full_lifecycle ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.29s

running 11 tests (tests\streaming_range_test.rs)
test test_path_traversal_denied ... ok
test test_range_initial_chunk ... ok
test test_nested_subdirectory_stream ... ok
test test_range_midstream_chunk ... ok
test test_options_cors ... ok
test test_nonexistent_file_404 ... ok
test test_full_file_stream_200 ... ok
test test_head_request_empty_body ... ok
test test_range_unsatisfiable_416 ... ok
test test_range_suffix ... ok
test test_range_open_ended ... ok
test result: ok. 11 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.40s

running 12 tests (tests\subtitles_test.rs)
test test_get_short_movie_name ... ok
test test_srt_to_vtt_conversion ... ok
test test_srt_to_vtt_offset_shift ... ok
test test_detect_subtitle_language ... ok
test test_subtitle_traversal_denied ... ok
test test_stream_subtitle_options_cors ... ok
test test_list_subtitles_catalog ... ok
test test_upload_subtitle_invalid_extension ... ok
test test_stream_subtitle_head_request ... ok
test test_stream_subtitle_vtt_200 ... ok
test test_upload_subtitle_multipart ... ok
test test_stream_subtitle_with_offset ... ok
test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.96s
```

### Compiler Hygiene (`cargo check`)

```text
Checking media-server-api v0.1.0 (E:\MediaServer\rust)
Finished `dev` profile [unoptimized + debuginfo] target(s) in 3.03s
Result: 0 errors, 0 warnings
```

---

## 4. Key Invariants & Hardening Retained

1. **Flask Cache Compatibility:** Reuses existing SHA-256 preview directories in `E:\MediaServer\cache\previews` without duplicate frame generation.
2. **Database Acceleration:** Uses PostgreSQL `progress` and `movies` tables to resolve durations without running `ffprobe` for indexed movies.
3. **Subdirectory Path Traversal Immunity:** Multi-level path splitting via `.rsplit_once('/')` with canonical containment verification.
4. **Asynchronous Non-Blocking Execution:** Uses `tokio::process::Command` ensuring FFmpeg operations never block Tokio worker threads.
5. **Atomic File Replacement:** Extracts frames to temporary `.part.jpg` files before atomic rename, preventing corrupted thumbnails during concurrent requests.
