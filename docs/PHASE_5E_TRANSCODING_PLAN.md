# Phase 5E Implementation Plan: HLS Delivery, Transcoding Support & End-to-End Concurrency Benchmarking

> **Document Type:** Sliced Migration Implementation Plan  
> **Repository:** `anis7t/media-server`  
> **Branch:** `feat/rust-api-foundation`  
> **Governing Document:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 5 & §Phase 6  
> **Preceding Deliverables:** Phase 5A (commit `d5d469a`), Phase 5B (commit `62000ce`), Phase 5C (commit `ea68bd3`), Phase 5D (commit `54b3a63`)  
> **Status:** 📋 **AWAITING USER APPROVAL**

---

## 1. Executive Summary & Architectural Scope

Phase 5E is the final capstone slice of **Phase 5: Media Library, Playback, and Streaming**. It delivers native Rust HLS playlist and chunk segment delivery, transcoded MP4 cache serving, and end-to-end multi-client streaming validation.

Per the architectural boundary established in [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 5 and §Phase 6:
- **Phase 5 Delivery Responsibility (Rust Axum)**:
  - Rust serves **all media delivery** paths: Direct Play byte ranges (`/media/{*path}`), HLS master playlists and segments (`/hls/{*path}`), transcoded MP4 cache files (`/transcode/{*path}`), seek-hover preview thumbnails (`/seek-preview/{*path}`), WebVTT subtitle tracks (`/subtitles/{*path}`), and watch progress (`/api/progress`).
- **Phase 6 Transcoding Orchestration Boundary**:
  - Deep multi-GPU FFmpeg worker scheduling (assigning chunk jobs between AMD RX 560X `dx11:1` and Vega 8 `dx11:0`, PTS offsets, and live engine telemetry) remains guarded and transitions to Rust in **Phase 6 (Rust Transcoding Worker)**.
  - In Phase 5E, Rust handles high-throughput serving of generated HLS playlists/segments, enforces RFC 8216 target duration honesty (`honest_target_duration`), handles in-flight transcode waiting/retries (HTTP 503 `Retry-After: 1`), and serves completed transcoded MP4 caches.

---

## 2. Deliverables & Endpoint Specifications

### 2.1 HLS Cache Resolution & Manifest Serving (`GET /hls/{*path}`)

#### Master Playlist Delivery (`GET /hls/{filename}/playlist.m3u8`):
1. **Media & Cache Directory Resolution**:
   - Resolves target video file across configured media roots (`PathResolver::resolve_media_path`).
   - Computes deterministic SHA-256 HLS candidate cache keys matching Python `get_hls_candidates`:
     - Primary key: `hls:{canonical_path}:{file_size}:{mtime_ns}` (with `\\?\` stripped).
     - Relative path cross-root keys: `hls:{root / rel}:{size}:{mtime_ns}`, `hls:{root / rel_clean}:{size}:{mtime_ns}`.
     - Fallback key: `hls:{filename}:{size}`.
   - Evaluates candidate directories in `cache/hls/` with priority:
     1. Fully completed playlist containing `#EXT-X-ENDLIST`.
     2. In-progress directory with highest segment/chunk progress.
     3. Primary directory for direct file path.
2. **RFC 8216 Playlist Healing (`honest_target_duration`)**:
   - Parses `#EXTINF:<duration>` labels across all segment entries.
   - Calculates `target = ceil(max(durations))`.
   - If `#EXT-X-TARGETDURATION:N` is missing or less than `target`, adjusts the manifest declaration so that target duration strictly bounds all emitted segments.
3. **Delivery & Status Responses**:
   - **Segments Ready**: HTTP 200 with `application/vnd.apple.mpegurl`, `Cache-Control: no-cache, max-age=0`.
   - **In-Flight / Transcoding in Progress (no segments yet)**: HTTP 503 with body `#EXTM3U\n#EXT-X-VERSION:3\n`, headers `Retry-After: 1` and `Cache-Control: no-cache, no-store, must-revalidate`.
   - **CORS Headers**: `Access-Control-Allow-Origin: *`, `Cross-Origin-Resource-Policy: cross-origin`, `Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges`.

#### Chunk Segment Delivery (`GET /hls/{filename}/{segment}`):
1. **Segment Validation**:
   - Enforces strict regex match: `^(init\.mp4|segment_\d{6}\.(m4s|ts))$`.
   - Rejects path separators, directory traversal (`..`), or unapproved extensions with HTTP 404.
2. **High-Throughput File Streaming**:
   - Locates segment inside the resolved HLS cache directory.
   - Serves using `RangeService` or streamed Tokio file reader:
     - MIME type: `video/mp2t` for `.ts`, `video/mp4` for `.m4s` and `init.mp4`.
     - Header: `Cache-Control: public, max-age=3600`.
     - Full CORS headers for Cast receivers (CAF) and web clients.

---

### 2.2 Transcoded MP4 Cache Serving (`GET /transcode/{*path}`)

1. **Deterministic Transcode Path Lookup**:
   - Identifies cache path: `cache/transcodes/{sha256}.mp4`.
   - Computes SHA-256 key matching Python:
     - `direct`: `sha256("{path}:{size}:{mtime_ns}")`.
     - `compat`: `sha256("compat:{path}:{size}:{mtime_ns}")`.
2. **RFC 7233 Byte-Range Playback**:
   - If transcoded MP4 exists, streams with `RangeService`:
     - HTTP 206 Partial Content (or 200 OK).
     - `Content-Range`, `Content-Length`, `Accept-Ranges: bytes`.
     - MIME type: `video/mp4`.
     - `Cache-Control: public, max-age=3600`.
   - If not cached / transcode in-flight: returns HTTP 503 or 404 with descriptive JSON.

---

### 2.3 OPTIONS Preflight Handling (`OPTIONS /hls/{*path}` & `/transcode/{*path}`)

- Returns HTTP 200 with:
  ```http
  Access-Control-Allow-Origin: *
  Access-Control-Allow-Methods: GET, HEAD, OPTIONS
  Access-Control-Allow-Headers: Range, Origin, Accept, Content-Type
  Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges
  Cross-Origin-Resource-Policy: cross-origin
  ```

---

## 3. Proposed Code Changes & Implementation Details

```text
rust/
├── Cargo.toml                          # Verify all dependencies (regex, sha2, tokio, mime_guess)
├── src/
│   ├── lib.rs                          # Mount HLS and Transcode routes with HlsState
│   ├── models/
│   │   ├── mod.rs                      # Export transcode models
│   │   └── transcode.rs                # Transcode status and HLS metadata models
│   ├── routes/
│   │   ├── mod.rs                      # Export hls and transcode modules
│   │   ├── hls.rs                      # GET & OPTIONS /hls/{*path}
│   │   └── transcode.rs                # GET & OPTIONS /transcode/{*path}
│   └── services/
│       ├── mod.rs                      # Export hls_service
│       └── hls_service.rs              # Candidate hashing, priority resolution, honest_target_duration
└── tests/
    └── hls_transcode_test.rs           # Integration tests asserting playlist, segments, honest duration, CORS
```

### Detailed Component Walkthrough:

1. **`rust/src/services/hls_service.rs`**:
   - `get_hls_candidates(path: &Path, roots: &[PathBuf]) -> Vec<String>`: Computes candidate hash set matching Python `transcode_service.py`.
   - `find_hls_dir(path: &Path, roots: &[PathBuf], cache_dir: &Path) -> PathBuf`: Checks candidate directories, inspects `playlist.m3u8` for `#EXT-X-ENDLIST`, and counts `.ts`/`.m4s` segments to resolve the best active cache directory.
   - `honest_target_duration(manifest: &str) -> String`: Extracts `#EXTINF:<duration>` labels, calculates `ceil(max(durations))`, and patches `#EXT-X-TARGETDURATION:<max>`.
   - `get_transcode_cache_path(path: &Path, mode: &str, cache_dir: &Path) -> PathBuf`: Generates deterministic transcoded MP4 path in `cache/transcodes/`.

2. **`rust/src/routes/hls.rs`**:
   - Parses the request URI: extracts `{filename}` and `{target}` (`playlist.m3u8` or segment filename).
   - If `playlist.m3u8`:
     - Checks if playlist exists and contains segments.
     - Formats playlist with `honest_target_duration`.
     - Returns HTTP 200 with `application/vnd.apple.mpegurl` and CORS.
     - If in progress / no segments: returns HTTP 503 `Retry-After: 1`.
   - If segment (`segment_000000.ts`, `segment_000000.m4s`, `init.mp4`):
     - Validates format via regex.
     - Serves with `RangeService` or Tokio file stream, setting `video/mp2t` or `video/mp4`.
   - If `OPTIONS`: returns preflight CORS response.

3. **`rust/src/routes/transcode.rs`**:
   - Handles `GET /transcode/{*filename}`.
   - Computes cache path; if present, streams with `RangeService` (RFC 7233 partial content).
   - If absent, returns 503 retry or 404.

4. **`rust/tests/hls_transcode_test.rs`**:
   - Integration tests covering:
     - Master playlist delivery with RFC 8216 `honest_target_duration` ceiling adjustment.
     - Manifest delivery with HTTP 200 and MIME type `application/vnd.apple.mpegurl`.
     - In-flight manifest HTTP 503 with `Retry-After: 1`.
     - Transport stream (`.ts`) delivery with `video/mp2t` and 206 range streaming.
     - Fragmented MP4 (`.m4s`) and `init.mp4` delivery with `video/mp4`.
     - Path traversal prevention (`..`) and invalid segment names returning 404.
     - Cached transcoded MP4 delivery with RFC 7233 byte-ranges.
     - CORS headers across all endpoints and `OPTIONS` preflight requests.

---

## 4. Verification & Testing Strategy

1. **Automated Unit & Integration Tests**:
   ```powershell
   .\scripts\cargo.bat test --test hls_transcode_test
   .\scripts\cargo.bat test --manifest-path rust\Cargo.toml
   .\scripts\cargo.bat check --manifest-path rust\Cargo.toml
   ```
2. **Compiler & Linter Hygiene**:
   - 0 compiler warnings (`cargo check`).
   - 100% test pass rate across the entire Rust test suite (target: >45 passing tests).
3. **End-to-End Concurrency Benchmark**:
   - Execute benchmark evaluation comparing Rust Axum against Flask Waitress.
   - Measure throughput (Mbps), time-to-first-byte (TTFB), and memory footprint.
4. **Walkthrough & Session Handoff**:
   - Render complete walkthrough in chat and persist to `docs/PHASE_5E_TRANSCODING_WALKTHROUGH.md`.
   - Update `docs/MIGRATION_STATUS.md` reflecting Phase 5 completion.
