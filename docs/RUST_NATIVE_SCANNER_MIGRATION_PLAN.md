# Implementation Plan: Native Rust Media Scanner Migration

## 1. Objective & Scope

Port the standalone Python ingestion script (`scanner.py`) into a native, high-performance, asynchronous Rust service integrated directly into the `media-server-api` Axum server. This permanently eliminates Python from the production runtime, achieving a **100% native Rust, React, and PostgreSQL** architecture.

### What Changes
- **New Rust Scanner Subsystem (`rust/src/scanner/` or `rust/src/services/scanner/`)**:
  - `parser.rs`: Regex title cleaning, release year extraction, scene release tag stripping, and anonymous/raw upload detection.
  - `models.rs`: Strongly typed Serde models for TMDb responses (movie details, genres, credits, certifications, trailers) matching the JSON structure persisted in PostgreSQL `movies.details_json`.
  - `tmdb_client.rs`: Async `reqwest`-based TMDb API client with rate limiting (429 Retry-After), exponential backoff (up to 4 attempts), and search/lookup routines (`/search/movie`, `/find/{id}`, `/movie/{id}`).
  - `engine.rs`: Media root traversal across configured paths (`D:\Flicks`, `D:\Flicks\.archive`, etc.), video extension filtering (`.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`), delta-detection against PostgreSQL `movies`, artwork caching via existing `TmdbArtworkService`, and SQLx upserts.
- **`ScanService` Refactoring (`rust/src/services/scan_service.rs`)**:
  - Replace the external Python subprocess execution (`tokio::process::Command::new(&py_exe).arg("scanner.py")`) with in-process asynchronous execution of the native Rust scanner.
  - Return accurate progress and ingestion metrics (`files_scanned`, `movies_indexed`, `transcodes_queued`).
- **Configuration (`rust/src/config.rs`)**:
  - Read `TMDB_API_TOKEN` into `AppConfig` from `.env` / environment variables.
- **Cargo Dependencies (`rust/Cargo.toml`)**:
  - Add `regex = "1.10"` and `walkdir = "2.5"` (or use `std::fs` / tokio recursive traversal).
- **Decommissioning**:
  - Delete `scanner.py`.

### What Deliberately Does Not Change
- The database schema for `movies` in PostgreSQL (`filename`, `title`, `year`, `tmdb_id`, `overview`, `poster_path`, `backdrop_path`, `runtime`, `genres`, `vote_average`, `updated_at`, `release_date`, `details_json`, `last_metadata_refresh`) remains identical to preserve compatibility with all clients (React SPA, Flutter Android, Fire TV 4K).
- The REST API endpoint contract for `POST /api/scan` and `GET /api/scan` remains identical.
- Artwork cache layout in `E:\MediaServer\cache\posters` and `E:\MediaServer\cache\backdrops` remains identical, leveraging existing `TmdbArtworkService`.

---

## 2. Technical Design & Architecture

```
                               ┌──────────────────────────────────────────────┐
                               │     POST /api/scan / Hourly Background       │
                               └──────────────────────┬───────────────────────┘
                                                      │
                                                      ▼
                                       ┌─────────────────────────────┐
                                       │     ScanService (Rust)      │
                                       └──────────────┬──────────────┘
                                                      │
                                                      ▼
                                     ┌─────────────────────────────────┐
                                     │     Native Scanner Engine       │
                                     └─┬──────────────┬──────────────┬─┘
                                       │              │              │
                    ┌──────────────────┘              │              └──────────────────┐
                    ▼                                 ▼                                 ▼
         ┌─────────────────────┐           ┌─────────────────────┐           ┌─────────────────────┐
         │ Filesystem Crawler  │           │   Filename Parser   │           │    TMDb Client      │
         │ (D:\Flicks, Archive)│           │ (Regex / Scene Tags)│           │ (Async reqwest / 429│
         └──────────┬──────────┘           └──────────┬──────────┘           │  Retry & Backoff)   │
                    │                                 │                      └──────────┬──────────┘
                    └──────────────────┬──────────────┘                                 │
                                       ▼                                                │
                          ┌─────────────────────────┐                                   │
                          │   PostgreSQL Delta      │◄──────────────────────────────────┘
                          │ (Find unindexed videos) │
                          └────────────┬────────────┘
                                       │
                                       ▼
                          ┌─────────────────────────┐
                          │   SQLx Upsert & Cache   │
                          │ (movies table + artwork)│
                          └─────────────────────────┘
```

### Key Components

#### A. Filename & Release Parser (`parser.rs`)
Faithfully reproduces Python's regex cleaning pipeline:
1. Strips prefixes: `^(?:Copy\s+of\s+)+`, leading bracketed noise `^[【\[].*?[】\]]\s*`, trailing duplicate markers `\s*\(\d+\)$`.
2. Converts `.` and `_` to spaces.
3. Extracts 4-digit release year: `\b(19\d{2}|20\d{2})\b` and truncates name at the year start.
4. Strips scene release tags: `1080p`, `2160p`, `4K`, `720p`, `480p`, `BluRay`, `BRRip`, `WEB[- ]?DL`, `WEBRip`, `HDRip`, `DVDRip`, `HDTV`, `x264`, `x265`, `HEVC`, `AVC`, `YIFY`, `RARBG`.
5. Anonymous upload classification: detects stems like `vid_`, `video_`, `mov_`, `movie_`, `dsc_`, `img_`, `untitled`, `unknown`, `file`, `upload`, `stream`, `part` or purely numeric/UUID strings to prevent invalid TMDb queries.

#### B. TMDb Async Client (`tmdb_client.rs`)
- Uses `reqwest::Client` with bearer token auth (`Authorization: Bearer <TMDB_API_TOKEN>`).
- Rate limiting: Respects HTTP 429 status code and `Retry-After` header.
- Endpoint queries:
  - `GET /3/search/movie?query={title}&year={year}&include_adult=false&language=en-US`
  - `GET /3/find/{clean_imdb_id}?external_source=imdb_id`
  - `GET /3/movie/{id}?language=en-US&append_to_response=credits,release_dates,videos`
- Details JSON synthesis:
  - Extracts certification from US/IN release dates.
  - Extracts top 20 cast members (`name`, `character`, `profile_path`).
  - Extracts directors and writers from crew.
  - Extracts production company names and YouTube trailer key.
  - Builds canonical JSON string for `movies.details_json`.

#### C. Database Synchronization & Ingestion (`engine.rs`)
- Computes relative path matching `PathResolver::resolve_media_path`.
- Queries indexed filenames: `SELECT filename FROM movies`.
- Identifies unindexed video files across configured media roots.
- Upserts records using SQLx:
  ```sql
  INSERT INTO movies (
      filename, title, year, tmdb_id, overview, poster_path, backdrop_path,
      runtime, genres, vote_average, updated_at, release_date, details_json, last_metadata_refresh
  ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
  ON CONFLICT (filename) DO UPDATE SET
      title = EXCLUDED.title,
      year = EXCLUDED.year,
      tmdb_id = EXCLUDED.tmdb_id,
      overview = EXCLUDED.overview,
      poster_path = EXCLUDED.poster_path,
      backdrop_path = EXCLUDED.backdrop_path,
      runtime = EXCLUDED.runtime,
      genres = EXCLUDED.genres,
      vote_average = EXCLUDED.vote_average,
      updated_at = EXCLUDED.updated_at,
      release_date = EXCLUDED.release_date,
      details_json = EXCLUDED.details_json,
      last_metadata_refresh = EXCLUDED.last_metadata_refresh;
  ```
- Downloads artwork via `TmdbArtworkService::get(pool, cache_dir, tmdb_id, ArtworkKind::Poster / Backdrop)`.

---

## 3. Exit Criteria

1. **Clean Compilation**: `cargo check --release` and `cargo build --release` succeed with zero errors.
2. **Deterministic Title Parsing**: Unit tests verify that filename parsing matches `scanner.py` across typical movie filenames (scene tags, years, editions, anonymous stems).
3. **Live Scan Verification**: Triggering `POST /api/scan` executes the native Rust scanner in-process, successfully scanning `D:\Flicks` and reporting completion without spawning Python.
4. **Zero Python in Production**: `scanner.py` is deleted, and no `.py` scripts are executed by `MediaServerRust`.
5. **Database Consistency**: All 35 active library movies remain intact and correctly represented in PostgreSQL.
6. **Persistent Service Verification**: NSSM service `MediaServerRust` restarts cleanly, serves `/api/movies`, `/api/scan`, and the React frontend without degradation.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation Strategy |
| :--- | :--- | :--- |
| **TMDb Rate Limiting (HTTP 429)** | Incomplete ingestion during large library scans | Implement bounded async retry loop checking `Retry-After` header with a 1-second delay between sequential lookups. |
| **Path Normalization Discrepancies** | Database `filename` mismatch causing duplicate rows | Standardize relative paths using `Path::strip_prefix` and forward slashes (`/`), matching `PathResolver::resolve_media_path`. |
| **TMDb Token Absence** | Scanner stalls or crashes on unconfigured environments | Check `config.tmdb_api_token` gracefully; log a descriptive warning and record basic metadata from filename/ffprobe rather than failing. |
| **File Lock / Disk Contention** | Concurrency conflicts while transcoding is active | Scanner only reads files and queries TMDb/PostgreSQL; it does not lock video files or interfere with transcode workers. |

---

## 5. Open Decisions

1. **Orphaned Record Pruning**:
   * **Option A (Strict reconciliation - Recommended)**: When a file is confirmed deleted from all media roots on disk, the scanner automatically removes its orphaned row from `movies` (mirroring how we handled deleted movies), preventing phantom library cards.
   * **Option B (Additive only)**: The scanner only adds/updates files and never deletes database rows (matching legacy `scanner.py` behavior).
2. **Stream Runtime Probing**:
   * **Option A (Probe fallback - Recommended)**: If TMDb returns `runtime = 0` or is unavailable, run `ProbeService::probe_cached(file_path)` to extract the exact container duration via `ffprobe`.
   * **Option B (TMDb only)**: Only use the runtime reported by TMDb (matching legacy `scanner.py`).
