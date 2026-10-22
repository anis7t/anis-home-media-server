# Phase 5C Implementation Plan: Subtitle & WebVTT Delivery Engine

**Branch:** `feat/rust-api-foundation`  
**Target:** Native Rust Media Server Subtitle Delivery & Upload Engine  
**Endpoints:**
- `GET /subtitles/{*path}` (Sidecar conversion to WebVTT with on-the-fly offset shifting)
- `GET /api/subtitles/{*filename}` (JSON catalog of available subtitle tracks)
- `POST /api/upload-subtitle/{*filename}` (Multipart subtitle upload with language auto-detection and canonical naming)

---

## 1. Objectives & Architectural Requirements

1. **On-The-Fly SRT to WebVTT Conversion (`/subtitles/{*path}`):**
   - Parse subpath into `(rel_video_filename, subtitle_name)` via rightmost path separation (`rsplit_once('/')`), supporting media in nested subdirectories without route collisions.
   - Resolve sidecar `.srt`/`.vtt` file next to media or across mirror storage roots (handling `.archive` roots).
   - Convert SRT syntax to WebVTT:
     - Header `WEBVTT\n\n`.
     - Timestamp normalization (`HH:MM:SS,mmm` → `HH:MM:SS.mmm`).
     - Optional time-shift query parameter `?offset=<seconds>` (supports float offsets like `?offset=1.5` or `-2.0`, clamped to `>= 00:00:00.000`).
     - Strips SRT cue index numbers.
   - Return `Content-Type: text/vtt; charset=utf-8` with CORS headers (`access-control-allow-origin: *`, `cross-origin-resource-policy: cross-origin`).

2. **Subtitle Track Catalog API (`GET /api/subtitles/{*filename}`):**
   - Resolve target video file across configured media roots.
   - Discover local sidecar `.srt` and `.vtt` subtitles matching the movie stem or short movie name (`<short_name>_<lang>_<n>.<ext>`).
   - Auto-detect language code and assign human-readable labels (`English (Local)`, `Hindi (Local)`, `Spanish (Local)`).
   - Mark the first English track as `default: true`.
   - Return `{ "tracks": [ { "id": "...", "name": "...", "src": "/subtitles/...", "lang": "...", "label": "...", "default": bool } ] }`.

3. **Multipart Subtitle Upload API (`POST /api/upload-subtitle/{*filename}`):**
   - Enable `multipart` feature in `axum` dependency (`Cargo.toml`).
   - Accept `multipart/form-data` with `subtitle` file part.
   - Validate extension: only `.srt` and `.vtt` permitted (returns 415 Unsupported Media Type for others).
   - Analyze text content via `detect_subtitle_language()`:
     - Unicode script inspection: Devanagari (`hi`), Cyrillic (`ru`), Hanzi (`zh`), Hiragana/Katakana (`ja`), Hangul (`ko`), Arabic (`ar`), Bengali (`bn`).
     - NLP stop-word frequency analysis: English, Spanish, French, German, Italian, Portuguese.
     - Fallback to `und`.
   - Compute short movie identifier and determine destination path with collision-free incremental counter: `<short_name>_<detected_lang>_<counter><ext>` (e.g. `gladiator_en_1.srt`).
   - Save directly next to the media file and return JSON `{ "success": true, "filename": "...", "language": "...", "path": "..." }`.

4. **Traversal & Security Safeguards:**
   - Multi-root canonical containment check (`PathResolver`) preventing directory traversal (`..`), UNC drive injection, or unauthorized file access outside configured media roots.

---

## 2. Planned Changes

### A. Dependencies (`rust/Cargo.toml`)
- Add `multipart` feature to `axum = { version = "0.8", features = ["json", "multipart"] }`.

### B. Subtitle Models (`rust/src/models/subtitle.rs`)
- `SubtitleTrack`: `id`, `name`, `src`, `lang`, `label`, `default`.
- `SubtitleListResponse`: `tracks: Vec<SubtitleTrack>`.
- `SubtitleUploadResponse`: `success: bool`, `filename: String`, `language: String`, `path: String`.

### C. Subtitle Service (`rust/src/services/subtitle_service.rs`)
- `srt_to_vtt(text: &str, offset_sec: f64) -> String`
- `shift_timestamp(ts: &str, offset_sec: f64) -> String`
- `detect_subtitle_language(text: &str) -> String`
- `get_short_movie_name(path: &Path) -> String`
- `resolve_sidecar_file(video_path: &Path, name: &str, roots: &[PathBuf]) -> Result<PathBuf, AppError>`
- `list_tracks(video_path: &Path, rel_filename: &str, roots: &[PathBuf]) -> Vec<SubtitleTrack>`

### D. Subtitle Routes (`rust/src/routes/subtitles.rs`)
- `subtitle_stream_handler`: `GET`, `HEAD`, `OPTIONS` at `/subtitles/{*path}`
- `list_subtitles_handler`: `GET` at `/api/subtitles/{*filename}`
- `upload_subtitle_handler`: `POST` at `/api/upload-subtitle/{*filename}`

### E. App Registration (`rust/src/lib.rs`)
- Mount subtitle routes on the Axum router with shared `Arc<Vec<PathBuf>>`.

### F. Integration Test Suite (`rust/tests/subtitles_test.rs`)
- 1. Test SRT to WebVTT conversion with comma-to-period replacement and counter stripping.
- 2. Test timestamp shifting with positive and negative offsets (`?offset=2.5`, `?offset=-1.0`).
- 3. Test language auto-detection for non-Latin (Devanagari, Cyrillic) and Latin (English, Spanish) scripts.
- 4. Test sidecar subtitle delivery via `GET /subtitles/{video}/{sub.srt}` (status 200, Content-Type `text/vtt; charset=utf-8`, CORS).
- 5. Test subtitle tracks listing via `GET /api/subtitles/{video}` (returns JSON array, first English track `default: true`).
- 6. Test multipart upload via `POST /api/upload-subtitle/{video}` (detects language, increments counter, returns JSON).
- 7. Test invalid file extension rejection (415 Unsupported Media Type).
- 8. Test traversal protection on subtitle paths (403/404).

---

## 3. Verification Plan

1. Run `.\scripts\cargo.bat check --manifest-path rust\Cargo.toml` to verify zero warnings.
2. Run `.\scripts\cargo.bat test --test subtitles_test --manifest-path rust\Cargo.toml` to verify all subtitle tests pass.
3. Run `.\scripts\cargo.bat test --manifest-path rust\Cargo.toml` to verify all 16 existing tests plus new subtitle tests pass simultaneously.
4. Deliver `docs/PHASE_5C_SUBTITLES_WALKTHROUGH.md` and present in chat.
