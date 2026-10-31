# Walkthrough: TMDb Metadata Enrichment, Scene Tag Parsing & Retry Resilience

## Executive Summary

The investigation into why **`Verity`** (`Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv`) lacked TMDb details after being uploaded through the web client revealed three interconnected root causes:

1. **Pre-Insertion Bypass in Scanner:**
   - The web upload completion handler (`build_success` in `rust/src/routes/ops/upload.rs`) inserted a minimal fallback record into the PostgreSQL `movies` table (`INSERT INTO movies (filename, title, year) VALUES (...) ON CONFLICT DO NOTHING`) so that the movie details link in the UI would work immediately.
   - However, `ScannerEngine::scan` in `rust/src/services/catalog/scanner/engine.rs` determined unindexed files by querying `SELECT filename FROM movies` and skipping any file present in `indexed_set`. Because the fallback row was already in the database, the scanner assumed the movie was already fully indexed and never contacted TMDb or populated `tmdb_id`, `overview`, `poster_path`, `backdrop_path`, `runtime`, or `details_json`.

2. **Crude Title Parsing in Upload Pipeline:**
   - `upload_service.rs::parse_title_year` simply replaced dots and underscores with spaces without stripping scene release tags (`1080p`, `WEB-DL`, `HEVC`, `x265`, `5.1`, `BONE`).
   - Consequently, the stored fallback title was `"Verity 2026 1080p WEB-DL HEVC x265 5 1 BONE"`. Even if a naive scan attempted to search TMDb with this raw string, TMDb would return zero results.

3. **ISP SNI Blocking on `api.themoviedb.org` & Lack of Multi-Host Retries:**
   - ISPs in India intermittently reset TLS handshakes (`Connection was reset`, `WinError 10054`) on `api.themoviedb.org`.
   - The alternate official CloudFront endpoint `api.tmdb.org` connects cleanly and fast. The TMDb client lacked domain fallback alternating between `api.tmdb.org` and `api.themoviedb.org` on retries, and lacked exponential backoff with `Retry-After` handling.

---

## Changes Implemented

### 1. Resilient TMDb Client with Domain Fallback & Exponential Retries
**File:** [`rust/src/services/catalog/scanner/tmdb_client.rs`](file:///e:/MediaServer/rust/src/services/catalog/scanner/tmdb_client.rs)
- Changed default API base URL from `https://api.themoviedb.org/3` to `https://api.tmdb.org/3`.
- Added automatic host fallback: if requests to the primary base URL encounter network resets or timeouts, subsequent retry attempts alternate to `https://api.themoviedb.org/3` (and vice-versa).
- Implemented 4-attempt exponential backoff (`delay = 2s * 2^(attempt - 1)`) with `Retry-After` header extraction on HTTP 429 rate limits.
- Added constructor helper `with_base_url` for testing and mocking without altering runtime environment variables.

### 2. Scene Tag Stripping in Upload Pipeline
**File:** [`rust/src/services/ops/upload_service.rs`](file:///e:/MediaServer/rust/src/services/ops/upload_service.rs)
- Replaced the regex logic in `parse_title_year` with a direct call to `FilenameParser::parse_filename(Path::new(filename))`.
- Automatically strips duplicate counter prefixes (`(1)`), brackets, scene tags (`1080p`, `2160p`, `4K`, `WEB-DL`, `HEVC`, `x265`, `BluRay`, `BRRip`, `YIFY`, `RARBG`, etc.), and extracts the release year.
- Updated unit tests to assert that `"The.Matrix.1999.1080p.mp4"` parses to `("The Matrix", Some(1999))` rather than retaining scene noise.

### 3. Incomplete Movie Detection & Metadata Enrichment in Scanner Engine
**File:** [`rust/src/services/catalog/scanner/engine.rs`](file:///e:/MediaServer/rust/src/services/catalog/scanner/engine.rs)
- Updated `ScannerEngine::scan` to query `SELECT filename, tmdb_id::BIGINT as tmdb_id, title, overview, last_metadata_refresh FROM movies`.
- Partitioned database records into:
  - **Indexed Set:** Movies with `tmdb_id IS NOT NULL`, plus movies verified within the last 4 hours to have no TMDb match.
  - **Incomplete Map:** Movies with `tmdb_id IS NULL` (such as pre-inserted upload rows) requiring metadata enrichment.
- Physical media files that either do not exist in the database or exist in the incomplete set are enqueued for ingestion.
- During ingestion:
  - The title is parsed via `FilenameParser::parse_filename`.
  - TMDb is queried with resilient retries using the parsed clean title and year.
  - If the parsed title does not match but an alternative custom title was provided in the upload pre-insertion, the alternative title is queried as a fallback.
  - On conflict, PostgreSQL `movies` row is updated with official TMDb ID, title, year, overview, poster path, backdrop path, runtime, genres, vote average, release date, and `details_json`.
  - Posters and backdrops are immediately downloaded and cached via `TmdbArtworkService::get`.

---

## Verification & Live Validation

### 1. Verification of `Verity` in Production Database
Upon building the release binary and starting `MediaServerRust`, the autonomous native scanner daemon executed and enriched `Verity` in PostgreSQL:

| Field | Before Fix | After Fix |
| :--- | :--- | :--- |
| **Filename** | `Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv` | `Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv` |
| **Title** | `Verity 2026 1080p WEB-DL HEVC x265 5 1 BONE` | `Verity` |
| **Year** | `2026` | `2026` |
| **TMDb ID** | `NULL` | `1283515` |
| **Overview** | `NULL` | *"Lowen Ashleigh, hired to ghostwrite for best-selling author Verity Crawford, uncovers Verity's autobiographical notes, and becomes involved in what may prove to be a lethal conspiracy."* |
| **Poster Path** | `NULL` | `/rmaNMA1seHqpjtnYKzyynFAr1g8.jpg` |
| **Backdrop Path** | `NULL` | `/cKetrF2dAnQ0AMV5i4BMOs41I5P.jpg` |
| **Genres** | `NULL` | `Mystery, Thriller` |
| **Runtime** | `NULL` | `117` min |
| **Vote Average** | `NULL` | `6.662` |
| **Release Date** | `NULL` | `2026-09-30` |
| **Details JSON** | `NULL` | Synthesized with cast, crew, certification, tagline, trailer key |
| **Last Refresh** | `NULL` | `1793479617` (active timestamp) |

### 2. Live Artwork Delivery Verification
- **Poster (`GET /tmdb-poster/1283515`):** Returns HTTP 200 with `image/jpeg` (43,740 bytes).
- **Backdrop (`GET /tmdb-backdrop/1283515`):** Returns HTTP 200 with `image/jpeg` (40,807 bytes).
- **Library List (`GET /api/movies`):** Verity includes `'poster': 'tmdb:1283515'`, clean title `'Verity'`, and all metadata.

### 3. Regression & CI Suite Results
- **Rust Backend:**
  - `cargo fmt --manifest-path rust/Cargo.toml --check`: Clean (0 diffs).
  - `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings`: Clean (0 warnings).
  - `cargo test --lib`: 131 passed, 0 failed.
  - `cargo test --test integration`: 254 passed, 0 failed.
  - Total Rust tests: **385 passed, 0 failed**.
- **Android API Contract Probe:**
  - `python scripts/probe_android_api.py`: **All 23 endpoints OK per contract**.
- **React Frontend (SPA):**
  - `npm --prefix web run typecheck`: Passed (0 errors).
  - `npm --prefix web run test`: **46 test files passed, 336 tests passed, 0 failed**.
- **Flutter Client:**
  - `flutter analyze`: **No issues found**.
  - `flutter test test/features/library/`: **All 48 tests passed, 0 failed**.
- **Service Liveness:**
  - `MediaServerRust` active on port 8000 via NSSM / Windows Service Manager.
