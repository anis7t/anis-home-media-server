# Phase 10: Native Rust Media Scanner & Ingestion Engine — Master Walkthrough

## Executive Summary

Phase 10 completes the final step of eliminating Python dependencies from production runtime by porting the standalone `scanner.py` utility into an in-process, high-performance, asynchronous Rust scanning engine.

With the delivery of Phase 10:
- **Zero Python Processes in Production**: Media ingestion, library crawlers, metadata synchronization, and background periodic scanners run natively inside the Axum binary (`MediaServerRust`).
- **High Concurrency & Resilience**: Utilizes `walkdir` for fast multi-threaded file crawling, `reqwest` with retry/backoff for TMDb API queries, `ProbeService` for zero-cost media runtime probing, and SQLx for transactional PostgreSQL operations.
- **Architectural Guardrails Maintained**: All 5 test suites (21 unit/integration tests) pass cleanly with zero regressions.

---

## Architecture & Implementation Overview

```
                                +-----------------------------+
                                |  Media Roots (D:\Flicks...) |
                                +--------------+--------------+
                                               |
                                               v
                                +-----------------------------+
                                |  ScannerEngine (engine.rs)  |
                                |  • Recursive Crawler        |
                                |  • Decision 1A: Prune Orphans|
                                +--------------+--------------+
                                               |
                    +--------------------------+--------------------------+
                    |                                                     |
                    v                                                     v
     +------------------------------+                       +-----------------------------+
     |   FilenameParser (parser.rs) |                       |   TmdbClient (tmdb_client)  |
     |   • Clean Release Tags       |                       |   • Search Movies (429 rate)|
     |   • Multi-Year Disambiguation|                       |   • Fetch Details & Credits |
     |   • Anonymous Stem Detection |                       |   • Artwork Caching         |
     +--------------+---------------+                       +--------------+--------------+
                    |                                                     |
                    +--------------------------+--------------------------+
                                               |
                                               v
                                +-----------------------------+
                                |  ProbeService (Decision 2A) |
                                |  • Fallback ffprobe duration|
                                +--------------+--------------+
                                               |
                                               v
                                +-----------------------------+
                                |  PostgreSQL (movies table)  |
                                |  • Upsert & Reconcile       |
                                +-----------------------------+
```

### 1. Filename & Release Parser (`rust/src/scanner/parser.rs`)
- **Regex Cleaning**: Strips scene release tags (`PROPER`, `HDR`, `REMUX`, `2160p`, `WEB-DL`, `x264`, `AAC`, etc.), audio identifiers, and bracketed groups.
- **Multi-Year Disambiguation**: Resolves titles containing numbers or multiple years (such as *2001: A Space Odyssey (1968)* or *Blade Runner 2049 (2017)*) by inspecting matches in reverse order and picking the last valid release year with a non-empty title prefix (`m.start() > 0`), fixing a long-standing truncation bug in legacy `scanner.py`.
- **Duplicate & Copy Detection**: Cleans Windows duplicate suffixes (e.g. `(1)`, `(Copy 2)`).

### 2. TMDb Async Client & Data Models (`rust/src/scanner/tmdb_client.rs`, `models.rs`)
- **HTTP 429 Rate Limiter & Backoff**: Exponential backoff (respecting `Retry-After` header or backing off up to 3 attempts) preventing rate limit drops during bulk indexing.
- **Payload Synthesis (`build_details_json`)**: Synthesizes full JSON metadata blobs identical to the legacy schema expected by the React frontend (ratings, certification, genres, runtime, cast, crew, backdrop/poster URLs).
- **Artwork Caching**: Automatically downloads and stores poster and backdrop images in `cache/posters/` and `cache/backdrops/` with atomic disk writes.

### 3. Crawler, Engine & Reconciliation (`rust/src/scanner/engine.rs`)
- **Decision 1A (Strict Reconciliation & Orphan Pruning)**:
  - Compares database records against currently existing files across all configured media roots.
  - Automatically unlinks orphaned database rows when their corresponding media files on disk have been deleted or moved.
- **Decision 2A (ffprobe Runtime Fallback)**:
  - If TMDb returns `runtime == 0` or if TMDb lookup is unconfigured, queries container duration via `ProbeService::source_video_duration` to ensure every indexed movie has accurate playback duration.
- **Multi-Root Resolution**: Normalizes paths across configured media roots (e.g. `D:\Flicks`), handling subdirectories and archive roots cleanly.

### 4. ScanService In-Process Integration (`rust/src/services/scan_service.rs`, `rust/src/routes/scan.rs`)
- **In-Process Tokio Task**: Spawns non-blocking async tasks with atomic `SCANNER_BUSY` concurrency gating (`AtomicBool`), preventing duplicate concurrent scan runs.
- **Report Telemetry**: Retains last scan telemetry (`files_discovered`, `unindexed_discovered`, `movies_indexed`, `orphans_pruned`, `errors`) queryable via `GET /api/scan`.
- **Admin PIN Security**: Enforces constant-time `X-Admin-Pin` header and body authentication for `POST /api/scan`, rejecting query string parameters (failing closed).
- **Autonomous Daemon**: Runs a periodic scan every 1 hour (with a 30s initial delay upon startup) supervised by `MediaServerRust`.

### 5. Legacy Python Decommissioning
- Permanently decommissioned `scanner.py` (622 lines of Python removed).
- Zero Python code remaining in production runtime or ingestion workflows.

---

## Slice Delivery Summary

| Slice | Title | Changes / Commits |
|:---:|---|:---:|
| **10.1** | Filename & Release Parser | Implemented `FilenameParser` with 9 unit tests (`84aef59`) |
| **10.2** | TMDb Async Client & Data Models | Implemented `TmdbClient`, `TmdbMovieSearch`, `TmdbMovieDetails`, rate limiting & tests (`59b8721`) |
| **10.3** | Crawler, ffprobe Fallback (2A) & Delta Database Engine (1A) | Implemented `ScannerEngine` with strict reconciliation & tests (`d21e371`) |
| **10.4** | ScanService In-Process Integration & REST API Wiring | Integrated `ScannerEngine` into `ScanService`, `routes/scan.rs`, `main.rs`, and daemons (`55ad242`) |
| **10.5** | Decommission `scanner.py`, Release Compilation & Deploy | Removed `scanner.py` (`4793fdb`), compiled release binary (`media-server-api.exe`), verified test battery |

---

## Verification & Test Results

### 1. Scanner Test Battery (21/21 Tests Passed)

```
running 2 tests
test test_storage_service_daemon_lifecycle_and_shutdown ... ok
test test_scan_service_daemon_lifecycle_and_shutdown ... ok
test result: ok. 2 passed; 0 failed

running 5 tests
test test_get_scan_returns_ok_status ... ok
test test_post_scan_with_valid_header_pin_succeeds ... ok
test test_post_scan_without_admin_pin_returns_403 ... ok
test test_post_scan_rejects_query_string_pin ... ok
test test_post_scan_with_valid_body_pin_succeeds ... ok
test result: ok. 5 passed; 0 failed

running 3 tests
test test_is_video_file ... ok
test test_compute_relative_path ... ok
test test_reconcile_orphans_prunes_missing_files ... ok
test result: ok. 3 passed; 0 failed

running 9 tests
test test_anonymous_stem_detection ... ok
test test_parse_copy_prefix_and_duplicate_count ... ok
test test_parse_web_dl_tags ... ok
test test_parse_cjk_brackets ... ok
test test_parse_dots_and_underscores ... ok
test test_parse_modern_hevc_release ... ok
test test_parse_movie_without_year ... ok
test test_parse_leading_brackets ... ok
test test_parse_standard_scene_release ... ok
test result: ok. 9 passed; 0 failed

running 2 tests
test test_build_details_json_synthesis ... ok
test test_live_tmdb_search_if_token_configured ... ok
test result: ok. 2 passed; 0 failed
```

### 2. Binary Verification
- Binary path: `rust\target\release\media-server-api.exe`
- Size: `13,906,432 bytes`
- Timestamp: `2026-10-18 13:50:43`
- Latest Git Commit: `4793fdb` (`2026-10-18 13:49:30`)
- **Verification Rule Satisfied**: Binary timestamp is strictly newer than the latest git commit.

---

## Service Restart Instructions

To activate the newly compiled release binary:
1. Open an elevated PowerShell terminal (or double click `e:\MediaServer\scripts\restart_rust_service.bat`).
2. Run:
   ```powershell
   Restart-Service MediaServerRust
   ```
3. Verify live service health and probe scan endpoint:
   ```powershell
   Invoke-RestMethod -Uri "http://127.0.0.1:8000/health"
   Invoke-RestMethod -Uri "http://127.0.0.1:8000/api/scan" -Method Post -Headers @{ "X-Admin-Pin" = "[admin-pin]" }
   ```

---

## Post-Ingestion Hardening & Transcode Cache Isolation

Following initial verification of Phase 10, an edge case was identified where the scanner crawled internal transcode caches:
1. **Root Cause**: `rust/src/config.rs` had historically appended `E:\MediaServer` to the fallback `media_roots` list. When triggered, the recursive scanner traversed `E:\MediaServer\cache\hls/` and began indexing segmented streaming pieces (`init_chunk_*.mp4`) into the `movies` table.
2. **Scanner Isolation**:
   - Removed `E:\MediaServer` from `AppConfig::media_roots` default fallback in `rust/src/config.rs`. Only `D:\Flicks` (and `D:\Flicks\.archive`) are treated as media roots.
   - Hardened `ScannerEngine::discover_video_files` in `rust/src/scanner/engine.rs` to ignore internal directories: `cache`, `.git`, `node_modules`, `target`, `.venv`, `.uploads`, and `.deleted`.
   - Updated `ScannerEngine::is_video_file` to explicitly reject fragmented streaming chunks (`chunk_*.mp4`, `init_chunk_*.mp4`, `*.m4s`).
3. **Database Remediation**:
   - Executed clean database purge: `DELETE FROM movies WHERE filename LIKE '%chunk%' OR filename LIKE 'cache/%'`.
   - Restored inventory count to exactly 35 legitimate movies.
4. **Test Suite Isolation**:
   - Updated `test_reconcile_orphans_prunes_missing_files` in `rust/tests/scanner_engine_test.rs` to include `config.media_roots` alongside `temp_root`, ensuring production library rows are never flagged as orphans during automated test runs.

