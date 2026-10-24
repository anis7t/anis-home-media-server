# Phase 5D Implementation Plan: Seek-Hover Frame Previews Engine

**Branch:** `feat/rust-api-foundation`  
**Target:** Native Rust Media Server Seek-Bar Hover Previews Engine  
**Endpoints:**
- `GET /api/seek-preview-meta/{*filename}` (Duration, sampling interval, thumbnail count, and base URL)
- `GET /seek-preview/{*path}` (On-demand frame extraction with persistent multi-root disk caching)
- `GET /preview-vtt/{*filename}` (Standard WebVTT seek storyboard for HLS/web/mobile players)

---

## 1. Objectives & Architectural Requirements

1. **Preview Metadata Endpoint (`GET /api/seek-preview-meta/{*filename}`):**
   - Resolve target video file across configured media roots (`PathResolver`).
   - Retrieve video duration:
     - Fast path: Query PostgreSQL `movies` table for `duration` (returns in <1ms without disk I/O).
     - Fallback path: Execute asynchronous `ffprobe` to read container/stream duration if not in database.
   - Dynamic sampling interval calculation:
     - `5.0s` for videos under 30 minutes (`duration < 1800.0s`).
     - `10.0s` for videos under 2 hours (`duration < 7200.0s`).
     - `15.0s` for feature films / videos 2 hours or longer (`duration >= 7200.0s`).
   - Thumbnail count calculation: `count = max(1, ((duration - 0.001) / interval).floor() as u64 + 1)`.
   - Return JSON: `{ "duration": f64, "interval": f64, "count": u64, "base_url": "/seek-preview/{filename}" }`.

2. **On-Demand Frame Extraction & Cache Serving (`GET /seek-preview/{*path}`):**
   - Parse `{filename}/thumb_{index:05d}.jpg` via `subpath.rsplit_once('/')`.
   - Validate index and format with regular expression / parsing (`thumb_(\d{5})\.jpg`).
   - SHA-256 cache key determination matching Python/Flask preview cache format:
     - `preview:{canonical_path}:{file_size}:{mtime_ns}`.
     - Multi-root candidate directory scanning allowing 100% instant reuse of pre-existing cached thumbnails from `E:\MediaServer\cache\previews`.
   - Cache hit: Serve `thumb_{index:05d}.jpg` directly with `image/jpeg`, `Cache-Control: public, max-age=86400`, conditional `ETag` and RFC 7233 byte-range support.
   - Cache miss:
     - Calculate seek timestamp: `min((duration - 0.05).max(0.0), index as f64 * interval)`.
     - Execute non-blocking Tokio process:
       `ffmpeg -hide_banner -loglevel error -ss {timestamp:.3f} -i {video_path} -frames:v 1 -vf scale=320:-2 -q:v 5 -y {temp_thumb}`.
     - Atomically rename `temp_thumb` to destination path.
     - Serve generated image.
   - Support `HEAD` (headers only) and `OPTIONS` (CORS preflight).

3. **WebVTT Seek Storyboard Endpoint (`GET /preview-vtt/{*filename}`):**
   - Generate standard WebVTT storyboard mapping time intervals to thumbnail URLs:
     ```text
     WEBVTT

     00:00:00.000 --> 00:00:15.000
     /seek-preview/{filename}/thumb_00000.jpg

     00:00:15.000 --> 00:00:30.000
     /seek-preview/{filename}/thumb_00001.jpg
     ```
   - Content-Type: `text/vtt; charset=utf-8` with CORS headers.

4. **Security & Process Safety Invariants:**
   - Strict `PathResolver` traversal protection.
   - Bounded FFmpeg execution timeout (10 seconds) with tempfile cleanup on failure.
   - Zero console signal broadcasting on Windows.

---

## 2. Planned Changes

### A. Dependencies (`rust/Cargo.toml`)
- Add `sha2 = "0.10"` and `hex = "0.4"` (both pre-cached in local `.cargo/registry`).

### B. Preview Models (`rust/src/models/preview.rs`)
- `SeekPreviewMetaResponse`: `duration: f64`, `interval: f64`, `count: u64`, `base_url: String`.

### C. Preview Service (`rust/src/services/preview_service.rs`)
- `get_preview_key(path: &Path) -> String`: Computes SHA-256 hash matching Flask convention.
- `get_preview_dir(path: &Path, cache_root: &Path, roots: &[PathBuf]) -> PathBuf`: Checks candidate directories, preferring pre-existing cached directories.
- `get_duration(path: &Path, pool: &PgPool) -> Result<f64, AppError>`: Queries Postgres `movies` first, falls back to `ffprobe`.
- `calculate_meta(duration: f64, rel_filename: &str) -> SeekPreviewMetaResponse`
- `ensure_thumbnail(video_path: &Path, index: u64, duration: f64, interval: f64, preview_dir: &Path) -> Result<PathBuf, AppError>`
- `generate_storyboard_vtt(meta: &SeekPreviewMetaResponse, rel_filename: &str) -> String`

### D. Preview Routes (`rust/src/routes/preview.rs`)
- `get_preview_meta_handler`: `GET /api/seek-preview-meta/{*filename}`
- `get_preview_thumb_handler`: `GET`, `HEAD`, `OPTIONS` at `/seek-preview/{*path}`
- `get_preview_vtt_handler`: `GET`, `HEAD`, `OPTIONS` at `/preview-vtt/{*filename}`

### E. App Registration (`rust/src/lib.rs`)
- Mount preview routes with shared `PreviewState` (`pool`, `media_roots`, `cache_dir`).

### F. Integration Test Suite (`rust/tests/preview_test.rs`)
- 1. Test preview meta calculation (sampling intervals for <30m, <2h, and >=2h videos).
- 2. Test SHA-256 cache key determinism and candidate discovery.
- 3. Test `GET /api/seek-preview-meta/{video}` returning 200 OK with correct duration, interval, count, and base URL.
- 4. Test `GET /seek-preview/{video}/thumb_00000.jpg` with on-demand extraction and cache generation (returns 200 OK, `image/jpeg`, valid JPEG magic bytes `\xFF\xD8\xFF`).
- 5. Test cache hit: Second request serves pre-existing thumbnail instantly without re-invoking FFmpeg.
- 6. Test `HEAD /seek-preview/...` returning metadata with empty body.
- 7. Test `OPTIONS /seek-preview/...` CORS preflight headers.
- 8. Test `GET /preview-vtt/{video}` returning valid WebVTT storyboard cues.
- 9. Test out-of-bounds thumbnail index clamping.
- 10. Test directory traversal rejection (403/404).

---

## 3. Verification Plan

1. Run `.\scripts\cargo.bat check --manifest-path rust\Cargo.toml` to verify 0 compiler warnings.
2. Run `.\scripts\cargo.bat test --test preview_test --manifest-path rust\Cargo.toml` to verify all preview tests pass.
3. Run `.\scripts\cargo.bat test --manifest-path rust\Cargo.toml` to verify all 28 existing tests + new preview tests pass.
4. Deliver `docs/PHASE_5D_PREVIEWS_WALKTHROUGH.md` and present in chat.
