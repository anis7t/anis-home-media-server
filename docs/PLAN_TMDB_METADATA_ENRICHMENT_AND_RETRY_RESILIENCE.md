# Implementation Plan — TMDb Metadata Enrichment, Resilient Retries & Upload Ingestion Fix

## 1. Problem Statement & Root Cause Analysis

An investigation into why the movie `Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv` (uploaded via web) has no TMDb details revealed three interlocking defects across the upload pipeline, library scanner, and external network layer:

1. **Pre-Insertion Bypass in Scanner (`rust/src/routes/ops/upload.rs` vs `rust/src/services/catalog/scanner/engine.rs`):**
   - On upload completion, `build_success` pre-inserts a fallback row into `movies` (`INSERT INTO movies (filename, title, year) ... ON CONFLICT DO NOTHING`) with the intended design: *"The scan will enrich this row."*
   - It then triggers `ScanService::trigger_scan()`.
   - However, `ScannerEngine::scan` computes `indexed_set = SELECT filename FROM movies` and filters discovered files with:
     ```rust
     if !indexed_set.contains(&rel) && !indexed_set.contains(&file_name) {
         unindexed.push((file, rel));
     }
     ```
   - Because `movies` already contained the placeholder row, the scanner considered the movie **already indexed** and skipped it completely. It never ran TMDb search or metadata enrichment.

2. **Crude Title Parsing in Upload Handler (`rust/src/services/ops/upload_service.rs`):**
   - `uploads::parse_title_year` simply replaced dots and underscores with spaces, without stripping release/scene tags (`1080p`, `WEB-DL`, `HEVC`, `x265`, `5.1`, `BONE`).
   - Consequently, the fallback title in the database became `"Verity 2026 1080p WEB-DL HEVC x265 5 1 BONE"` instead of `"Verity"`.
   - The robust, canonical parser already exists in `rust/src/services/catalog/scanner/parser.rs` (`FilenameParser::parse_filename`), but the upload handler was not utilizing it.

3. **ISP-Level Domain Filtering on `api.themoviedb.org` & Network Retry Constraints:**
   - In India (and several regional ISPs), `api.themoviedb.org` is blocked/filtered at the SNI/network level, causing TLS handshakes to fail with `Connection was reset` (`WinError 10054` / `curl (35) Recv failure`).
   - TMDb's official alternate domain `https://api.tmdb.org/3` routes through CloudFront cleanly without resets and returns metadata immediately.
   - While `TmdbClient` has basic retry loops, when the host is unreachable or rate-limited, it needs robust retry logic with exponential backoff and domain fallback to ensure transient network glitches or ISP resets do not discard movie metadata.

---

## 2. Scope

### In Scope
- **Domain & Resilient Retry Hardening (`rust/src/services/catalog/scanner/tmdb_client.rs`):**
  - Set default TMDb base URL to `https://api.tmdb.org/3` (with `TMDB_API_BASE_URL` env override remaining respected).
  - Add multi-host fallback: if a request to `api.themoviedb.org` fails with a connection/network reset error, transparently retry against `api.tmdb.org` (and vice-versa).
  - Harden retry delays: exponential backoff with jitter and `Retry-After` header adherence for HTTP 429 and 5xx responses.
- **Scanner Metadata Enrichment for Incomplete Rows (`rust/src/services/catalog/scanner/engine.rs`):**
  - Update `ScannerEngine::scan` to identify not only unindexed physical files, but also **partially indexed files** (files present on disk whose database row has `tmdb_id IS NULL`).
  - Pass these incomplete rows through `FilenameParser::parse_filename` and `TmdbClient::search_movie` to enrich title, year, TMDb ID, overview, poster path, backdrop path, runtime, genres, and ratings.
- **Upload Pipeline Title Parsing Fix (`rust/src/services/ops/upload_service.rs` & `rust/src/routes/ops/upload.rs`):**
  - Update `uploads::parse_title_year` (or delegate directly) to use `FilenameParser::parse_filename` from the scanner module, guaranteeing scene tags (`1080p`, `WEB-DL`, etc.) are stripped cleanly at upload time.
- **Immediate Verity Resolution & Database Re-Sync:**
  - Execute library scan or refresh so that `Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv` is enriched with official TMDb ID `1283515`, poster `/rmaNMA1seHqpjtnYKzyynFAr1g8.jpg`, and complete synopsis.
- **Full 4-Pillar Verification & Regression Suite:**
  - All unit/integration tests in Rust, React, Flutter, and Android API probe must pass cleanly.

### Deliberately Out of Scope
- No changes to authentication, Google OTP, or user roles.
- No changes to video transcode pipeline or player components.

---

## 3. Implementation Steps

### Phase 1: TMDb Client Domain Fallback & Resilient Retries (`tmdb_client.rs`)
1. Change `const TMDB_API_BASE: &str` default to `"https://api.tmdb.org/3"`.
2. Enhance `get_with_retry`:
   - If a request fails with network error / connection reset on the active base URL, switch to the alternative domain (`api.tmdb.org` ↔ `api.themoviedb.org`) on subsequent retry attempts.
   - Retries: 4 attempts with exponential backoff (`delay = base * (2^(attempt-1)) + jitter`).

### Phase 2: Upload Service Title Parsing (`upload_service.rs` & `upload.rs`)
1. Replace regex logic in `upload_service.rs::parse_title_year` with a call to `crate::services::catalog::scanner::FilenameParser::parse_filename(Path::new(filename))`.
2. Ensure scene tags and noise are stripped when generating fallback records upon upload completion.

### Phase 3: Scanner Unindexed & Incomplete Row Detection (`engine.rs`)
1. In `ScannerEngine::scan`:
   - Query existing rows:
     ```sql
     SELECT filename, tmdb_id FROM movies
     ```
   - Partition into:
     - Fully indexed filenames (`tmdb_id IS NOT NULL`).
     - Incompletely indexed filenames (`tmdb_id IS NULL`).
   - Any physical file that either does not exist in `movies` OR exists with `tmdb_id IS NULL` is enqueued for ingestion/enrichment.
2. In the ingest loop:
   - Run TMDb query with retries.
   - The existing `INSERT ... ON CONFLICT (filename) DO UPDATE SET title = EXCLUDED.title, tmdb_id = EXCLUDED.tmdb_id, overview = EXCLUDED.overview, ...` will cleanly update the record in PostgreSQL.

### Phase 4: Verification & Live Re-Sync
1. Run `cargo test --manifest-path rust/Cargo.toml -- --test-threads=1`.
2. Trigger library scan on live service (`MediaServerRust`).
3. Query `movies` table in PostgreSQL to verify that `Verity` now has:
   - `tmdb_id = 1283515`
   - `title = 'Verity'`
   - `year = 2026`
   - `poster_path = '/rmaNMA1seHqpjtnYKzyynFAr1g8.jpg'`
   - `overview` is populated.
4. Verify Android API probe (`python scripts/probe_android_api.py`).

---

## 4. Exit Criteria

- [ ] `tmdb_client.rs` connects reliably to TMDb API using `https://api.tmdb.org/3` with multi-attempt exponential retries and fallback.
- [ ] Uploaded movies use `FilenameParser::parse_filename` so scene release tags are stripped from fallback title entries.
- [ ] `ScannerEngine::scan` enriches movies that have `tmdb_id IS NULL` in the database.
- [ ] In PostgreSQL `movies` table, `Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv` has non-null `tmdb_id`, clean title `"Verity"`, year `2026`, poster path, and overview.
- [ ] Full local CI suite passes (Rust tests, React typecheck/lint/tests, Flutter analyze/tests, probe script).

---

## 5. Risks & Mitigation

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| TMDb API token rate-limiting on rapid sequential scans | Scan delays or 429 errors | `get_with_retry` checks `Retry-After` header and applies exponential backoff delays. |
| Re-scanning files without TMDb matches repeatedly | Unnecessary API calls every scan | Scans only attempt enrichment for files where `tmdb_id IS NULL` and record timestamps. If TMDb returns 404/no match, scanner still records `last_metadata_refresh` or fallback title so it does not loop. |
| Overwriting custom user titles on scan | User title overrides lost | `FilenameParser` preserves user-provided title overrides passed during upload. |

---

## 6. Open Decisions

1. **Alternate Domain Preference:**
   - **Option A (Recommended):** Use `https://api.tmdb.org/3` as the primary base URL with fallback to `https://api.themoviedb.org/3` on failure. (Proven to bypass ISP resets across Indian networks).
   - **Option B:** Keep `api.themoviedb.org` as primary, but catch connection reset and immediately retry with `api.tmdb.org`.
