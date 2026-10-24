# Implementation Plan — Proactive Subtitle Acquisition (Category 5.4)

## 1. Executive Summary & Objective

- **Context:** Movies currently acquire subtitles from OpenSubtitles on an *on-demand* basis (`SubtitleService::fetch_online_subtitle`). When a user begins playback on a title lacking embedded or sidecar English subtitles, the player synchronously blocks while `get_subtitle_tracks` executes a 64-bit MovieHash calculation, OpenSubtitles REST queries, HTTP fallback search by title, gzip download, and decompression. This induces an 8–10 second visual delay before subtitles appear. Furthermore, if OpenSubtitles experiences rate-limiting, network jitter, or finds no matching subtitle, every playback attempt redundantly repeats the 8-second query.
- **Identified Defects & Architectural Gaps:**
  1. **Playback Interruption & Latency:** First-time playback on titles without local English tracks suffers an 8-second initial blocking phase while querying external APIs.
  2. **Negative Query Churn:** Titles for which OpenSubtitles has no subtitles (`None`) have no negative-match caching. Every player load, scan, or metadata lookup repeats the 8-second network timeout.
  3. **No Ingestion Pipeline Hook:** The native scanner (`ScannerEngine::scan`) indexes video files and fetches TMDb metadata/artwork, but leaves subtitle acquisition uninvoked until user playback.
- **Objective:** Implement proactive, polite, background subtitle acquisition within the native Rust scanner engine and background worker pipeline. When a movie is ingested, or during background library maintenance, detect whether English subtitles are already present (embedded container stream or local sidecar). If missing, proactively fetch, decompress, convert to WebVTT, and cache the OpenSubtitles track in `cache/subtitles/online/{short_hash}.vtt`. Introduce negative-match caching to eliminate redundant API spam, add telemetry tracking (`subtitles_acquired`), and verify with dedicated Rust integration tests.

---

## 2. Proposed Changes & Architecture

### A. Subtitle Service Enhancements (`rust/src/services/subtitle_service.rs`)
1. **Negative Match Caching (`.nomatch`):**
   - When OpenSubtitles returns no results for a video hash/title, write a lightweight marker file: `online_cache_dir/{short_hash}.nomatch`.
   - In `fetch_online_subtitle()`, before issuing network requests, check if `{short_hash}.nomatch` exists:
     - If it exists and was modified within the last 24 hours, return `None` immediately (0ms latency, zero API spam).
     - If older than 24 hours, expire and re-evaluate.
2. **Has English Subtitles Probe Helper (`has_english_subtitles`):**
   - Pure check: evaluates whether local sidecar files (`.srt` / `.vtt`) in the movie directory or embedded container tracks (`probe_embedded_subtitles`) or existing cached online tracks (`cache/subtitles/online/{short_hash}.vtt`) provide an English subtitle (`lang == "en"`).
3. **Proactive Ingestion Acquisition (`ensure_subtitles_for_movie`):**
   - Checks `has_english_subtitles(video_path, cache_dir)`.
   - If true, returns `Ok(false)` (no download necessary).
   - If false, invokes `fetch_online_subtitle(video_path, title, cache_dir)`.
   - Returns `Ok(true)` if a new subtitle was downloaded and cached.

### B. Native Scanner Engine Integration (`rust/src/scanner/engine.rs`)
1. **New Movie Ingestion:**
   - In `ScannerEngine::scan()`, after indexing unindexed video files and caching TMDb artwork, call `SubtitleService::ensure_subtitles_for_movie(&path, &final_title, &cache_dir_buf)`.
   - Increment `report.subtitles_acquired` when a new subtitle is cached.
2. **Library Proactive Sweep (`proactive_subtitle_sweep`):**
   - During scheduled background library scans or manual scan requests, run a polite sweep over existing library movies that lack English subtitles.
   - Throttle requests with a 500ms delay between consecutive OpenSubtitles API calls to respect public API rate limits.
   - Respect negative-match caches so already-checked movies without online subtitles are skipped instantly.
3. **Telemetry & Scan Response:**
   - Add `subtitles_acquired: usize` to `ScannerReport` and `ScanResponse` in [`rust/src/services/scan_service.rs`](../rust/src/services/scan_service.rs).

### C. Scope Boundaries (What Deliberately Does NOT Change)
- **Zero Playback Disruption:** In-player subtitle track resolution (`/api/subtitles/<path:filename>`) remains 100% backward-compatible. Because tracks are pre-cached, `get_subtitle_tracks` serves the local file in 0ms.
- **Embedded & Local Precedence Invariant:** Local sidecars (`.srt`/`.vtt`) and embedded MKV/MP4 streams strictly retain priority over online downloads.
- **No Python or Reverse Proxy Dependencies:** 100% native Rust reqwest/flate2 in Axum.

---

## 3. Exit Criteria

- [ ] **Negative Match Cache:** OpenSubtitles queries that yield no results create a 24-hour `.nomatch` marker, preventing repeated 8s network delays.
- [ ] **Proactive Ingestion:** Newly discovered/uploaded video files automatically trigger subtitle acquisition if lacking local/embedded English tracks.
- [ ] **Background Sweep:** Scanner engine includes throttled (500ms delay) sweep for existing movies missing subtitles.
- [ ] **Telemetry:** `ScannerReport` and `ScanResponse` report `subtitles_acquired`.
- [ ] **Integration Test Suite:** Dedicated Rust test suite [`rust/tests/subtitle_test.rs`](../rust/tests/subtitle_test.rs) verifying:
  - OpenSubtitles hash calculation correctness.
  - Skip acquisition when embedded or sidecar English subtitles exist.
  - Negative cache creation and fast-path bail-out.
  - Proactive acquisition flow.
- [ ] **Full Regression Suite:** `qr_auth_test`, `audit_log_test`, `user_progress_test`, `admin_auth_test`, `api_contracts_test`, and `probe_android_api.py` all pass with zero failures.
- [ ] **Release Deployment:** Optimized release binary built and running on port 8000.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **OpenSubtitles Rate Limiting** | HTTP 429 Too Many Requests if scanning large library | 500ms polite delay between requests, 24-hour negative match caching, and graceful failure handling (continues scan without aborting). |
| **I/O Overhead on Large Video Files** | Computing 64-bit MovieHash reads 128KB (first 64KB + last 64KB) | OpenSubtitles hash reads only 128KB total regardless of file size (does not scan entire file). |
| **Network Latency Blocking Server Scan** | Scanner takes longer to complete if many movies lack subtitles | Runs asynchronously during scan pipeline; skips if embedded track is already present. |

---

## 5. Open Decisions

1. **Scope of Proactive Acquisition Sweep:**
   - **Option A (Recommended):** Acquire proactively on new movie ingestion AND run a polite, throttled background sweep during library scan for existing movies lacking English subtitles (with 500ms delay per query and 24h negative cache for movies without matches).
   - **Option B:** Strict New Ingestion Only: Only acquire proactive subtitles for newly uploaded/discovered media files; existing library files remain on-demand only.
2. **Negative Match Caching Duration:**
   - **Option A (Recommended):** 24-hour negative cache (`.nomatch` marker file) so subsequent player requests or scans don't hang for 8 seconds when OpenSubtitles has no subtitles for a title, but can re-try after 24 hours.
   - **Option B:** Permanent negative cache until file is modified or user manually uploads a subtitle.
