# Phase 10: Native Rust Media Scanner & Ingestion Engine
## Structured Migration & Execution Plan

**Status:** Plan Approved (Options 1A & 2A selected) — Ready for Execution  
**Target:** 100% Elimination of Python from Production Runtime  
**Stack:** 100% Native Rust (`axum`, `tokio`, `sqlx`, `reqwest`, `regex`) + React 19 SPA + PostgreSQL 18.4  

---

## 1. Executive Summary & Architectural Scope

Following the successful completion of **Phase 7 Slice 7E** (Legacy Flask Decommissioning), the Media Server runs exclusively on native Rust Axum (`:8000`), React 19 SPA, and PostgreSQL 18.4. The single remaining non-Rust component in the runtime is `scanner.py`, which is spawned as an external Python subprocess by `ScanService` for library ingestion.

**Phase 10** completely ports and embeds the library scanning and TMDb metadata ingestion engine natively into the Rust backend (`media-server-api`), officially decommissioning `scanner.py`.

### Selected Architectural Decisions
- **Decision 1A (Strict Reconciliation / Orphaned Pruning)**: When a video file is permanently deleted from all media roots on disk (such as *Project Hail Mary* or removed test videos), the native scanner automatically prunes its orphaned database row from `movies`, guaranteeing zero phantom library cards.
- **Decision 2A (ffprobe Container Duration Fallback)**: If TMDb reports `runtime = 0` or metadata is unavailable (e.g. home videos, obscure films, or unindexed titles), the native scanner invokes `ProbeService::probe_cached` to populate exact duration and stream dimensions directly from `ffprobe`.

---

## 2. Phase 10 Structured Execution Slices

```
 Phase 10: Native Rust Media Scanner Engine
 ├── Slice 10.1: Filename & Release Parser (Regex Cleaning & Scene Tag Stripping)
 ├── Slice 10.2: TMDb Async Client & Data Models (429 Rate Limiter & JSON Synthesizer)
 ├── Slice 10.3: Crawler, ffprobe Fallback (2A) & Delta Database Engine (1A)
 ├── Slice 10.4: ScanService In-Process Integration & REST API Wiring
 └── Slice 10.5: Decommission scanner.py, Full Verification Battery & Service Restart
```

---

### Slice 10.1: Filename & Release Parser (`rust/src/scanner/parser.rs`)
* **Objective**: Port all regex title cleaning, scene release tag stripping, year extraction, and anonymous stem heuristics to native Rust with zero behavioral divergence from `scanner.py`.
* **Deliverables**:
  1. Add `regex = "1.10"` to `rust/Cargo.toml`.
  2. Implement `rust/src/scanner/parser.rs`:
     - `parse_filename(path: &Path) -> (String, Option<i32>)`:
       - Strips prefixes: `^(?:Copy\s+of\s+)+`, leading bracket tags `^[【\[].*?[】\]]\s*`, duplicate markers `\s*\(\d+\)$`.
       - Replaces dots and underscores with spaces.
       - Extracts 4-digit release year `\b(19\d{2}|20\d{2})\b` and truncates name at the year start.
       - Strips scene release tags (`1080p`, `2160p`, `4K`, `720p`, `480p`, `BluRay`, `BRRip`, `WEB-DL`, `WEBRip`, `HDRip`, `DVDRip`, `HDTV`, `x264`, `x265`, `HEVC`, `AVC`, `YIFY`, `RARBG`).
     - `is_anonymous_name(stem: &str) -> bool`:
       - Flags generic or camera stems (`vid_`, `video_`, `mov_`, `movie_`, `dsc_`, `img_`, `untitled`, `unknown`, `file`, `upload`, `stream`, `part`, UUIDs) to prevent erroneous TMDb lookups.
  3. Comprehensive unit test suite in `rust/tests/scanner_parser_test.rs` asserting parity against 20+ representative real-world filenames.
* **Exit Criteria**: `cargo test test_scanner_parser` passes 100%.

---

### Slice 10.2: TMDb Async Client & Data Models (`rust/src/scanner/tmdb_client.rs`, `rust/src/scanner/models.rs`)
* **Objective**: High-performance, rate-limited async TMDb API client using `reqwest` and Serde.
* **Deliverables**:
  1. Update `AppConfig` in `rust/src/config.rs` to load `tmdb_api_token: Option<String>`.
  2. Implement `rust/src/scanner/models.rs`:
     - Strongly typed Serde models for TMDb responses (`TmdbSearchResponse`, `TmdbMovieResult`, `TmdbMovieDetails`, `TmdbCredits`, `TmdbReleaseDates`, `TmdbVideos`).
  3. Implement `rust/src/scanner/tmdb_client.rs`:
     - Bearer token authentication header (`Authorization: Bearer <TOKEN>`).
     - Bounded async retry loop handling HTTP 429 (`Retry-After` header) and network drops with exponential backoff (up to 4 attempts).
     - `search_movie(title: &str, year: Option<i32>) -> Result<Option<TmdbMovieResult>, AppError>`:
       - Prefers exact release-year match when multiple results are returned.
     - `find_by_imdb_id(imdb_id: &str) -> Result<Option<TmdbMovieResult>, AppError>`.
     - `get_movie_details(tmdb_id: i64) -> Result<TmdbMovieDetails, AppError>` (with `append_to_response=credits,release_dates,videos`).
     - `build_details_json(details: &TmdbMovieDetails) -> serde_json::Value`:
       - Synthesizes `tagline`, `imdb_id`, US/IN `certification`, top 20 `cast`, `directors`, `writers`, `production`, and YouTube `trailer_key`.
* **Exit Criteria**: Integration test against mock or live TMDb endpoint succeeds with valid JSON output.

---

### Slice 10.3: Crawler, ffprobe Fallback (2A) & Delta Database Engine (`rust/src/scanner/engine.rs`)
* **Objective**: Filesystem discovery, SQLx database delta tracking, artwork caching, and strict reconciliation.
* **Deliverables**:
  1. Add `walkdir = "2.5"` to `rust/Cargo.toml`.
  2. Implement `rust/src/scanner/engine.rs`:
     - Crawl configured media roots (`D:\Flicks`, `D:\Flicks\.archive`), skipping `.uploads` and `.deleted`.
     - Filter supported video extensions (`.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`).
     - Delta resolution:
       - Query all existing records: `SELECT filename FROM movies`.
       - Identify unindexed video files on disk.
     - **Decision 2A Implementation**:
       - If TMDb returns `runtime == 0` or lookup fails, invoke `ProbeService::probe_cached` to get the container duration and stream dimensions.
     - **Decision 1A Implementation (Strict Reconciliation)**:
       - Detect any database rows in `movies` whose files no longer exist in any media root on disk and remove them (`DELETE FROM movies WHERE filename = $1`).
     - SQLx transactional upsert inserting full metadata into `movies`.
     - Cache artwork via `TmdbArtworkService::get(...)` for posters and backdrops.
* **Exit Criteria**: Engine successfully resolves delta against test fixtures and PostgreSQL.

---

### Slice 10.4: ScanService In-Process Integration & REST API Wiring (`rust/src/services/scan_service.rs`)
* **Objective**: Embed the native scanner directly into the running Axum server and update scan telemetry.
* **Deliverables**:
  1. Refactor `rust/src/services/scan_service.rs`:
     - Replace `tokio::process::Command::new(&py_exe).arg("scanner.py")` with `tokio::spawn` calling `ScannerEngine::run_scan(...)`.
     - Retain `SCANNER_BUSY: AtomicBool` lock guard to prevent concurrent scans.
     - Enhance `ScanResponse` to report real live statistics:
       ```rust
       pub struct ScanResponse {
           pub status: String,
           pub busy: bool,
           pub files_scanned: usize,
           pub movies_indexed: usize,
           pub orphans_pruned: usize,
           pub errors: usize,
       }
       ```
  2. Connect the hourly background daemon in `rust/src/main.rs` to the native scanner engine.
  3. Ensure `POST /api/scan` and `GET /api/scan` interact directly with the in-process scanner.
* **Exit Criteria**: `POST /api/scan` executes in-process and returns HTTP 200 with accurate metrics.

---

### Slice 10.5: Decommission `scanner.py`, Verification Battery & Production Cutover
* **Objective**: Remove `scanner.py`, run verification battery, rebuild release binary, and verify production NSSM service.
* **Deliverables**:
  1. Delete `e:\MediaServer\scanner.py`.
  2. Run full test suites:
     - `cargo check --release`
     - `cargo test`
  3. Build optimized release binary `cargo build --release`.
  4. Restart NSSM Windows service `MediaServerRust` via elevated batch script.
  5. Verify executable timestamp and live endpoints:
     - `GET http://127.0.0.1:8000/api/movies` (all 35 movies present).
     - `POST http://127.0.0.1:8000/api/scan` (runs native in-process scan).
  6. Update `docs/MIGRATION_STATUS.md`, `docs/PROJECT_STATUS.md`, and master handoff.
* **Exit Criteria**: 0% Python running in production; `MediaServerRust` binary verified live and serving all requests.

---

## 3. Verification & Safety Protocols

1. **Database Safety**: Never drop the `movies` table; all operations use `ON CONFLICT (filename) DO UPDATE` or targeted `DELETE` for verified missing files only.
2. **Path Normalization**: Canonical relative paths use forward slashes (`/`), matching `PathResolver::resolve_media_path` across drives `D:` and `E:`.
3. **No Interactive Push**: All changes will be committed locally to git; push is reserved exclusively for the user.
