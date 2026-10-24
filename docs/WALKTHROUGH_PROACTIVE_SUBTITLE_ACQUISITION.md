# Walkthrough — Proactive Subtitle Acquisition (Category 5.4)

## 1. Executive Summary

We have fully implemented, tested, and deployed the fix for **Category 5.4: Proactive Subtitle Acquisition**.

- **Eliminated Playback Latency & Network Blocking:** Previously, subtitle acquisition occurred on-demand when a user loaded the video player (`get_subtitle_tracks`). For titles without embedded English tracks, the player blocked for up to 8–10 seconds waiting for OpenSubtitles hash computation, REST queries, title searches, gzip download, and decompression. Subtitles are now proactively acquired ahead of time in the background during library scanning and new media ingestion, allowing the player to resolve subtitle tracks in 0ms directly from local cache.
- **24-Hour Negative Match Caching (`.nomatch`):** When OpenSubtitles has no subtitles for a media file or stem, `fetch_online_subtitle` now writes a 24-hour `.nomatch` marker file (`cache/subtitles/online/{short_hash}.nomatch`). Subsequent playback requests or library scans skip external network calls instantly (< 1ms), completely eliminating repeated 8-second query churn.
- **Embedded & Local Precedence Invariant Preserved:** `SubtitleService::has_english_subtitles()` performs a fast multi-source check: if the video file already possesses an English sidecar (`.srt` / `.vtt`), an embedded container subtitle stream (detected via `ffprobe`), or a pre-cached online track, external network lookups are skipped entirely.
- **Polite Library Sweep (Option A):** In [`rust/src/scanner/engine.rs`](../rust/src/scanner/engine.rs), `ScannerEngine::proactive_subtitle_sweep()` sweeps existing library movies lacking English subtitles with a polite 500ms throttle between consecutive OpenSubtitles calls, respecting public rate limits.
- **Telemetry & Telemetry API:** Added `subtitles_acquired: usize` to `ScannerReport` and `ScanResponse` (`GET /api/scan`).
- **Integration Tests & Full Regression Pass:** Dedicated Rust test suite [`rust/tests/subtitle_test.rs`](../rust/tests/subtitle_test.rs) passed 5/5 tests; full regression suite (`qr_auth_test`, `audit_log_test`, `user_progress_test`, `admin_auth_test`, `api_contracts_test`, and `probe_android_api.py`) passed with zero errors.
- **Production Service Deployed:** Rebuilt the optimized release binary and restarted the `MediaServerRust` Windows service, healthy on port 8000.

---

## 2. Changes Implemented

### A. Subtitle Service Enhancements (`rust/src/services/subtitle_service.rs`)
1. **24-Hour Negative-Match Caching in `fetch_online_subtitle`:**
   ```rust
   // Check 24-hour negative-match cache marker
   let nomatch_target = online_cache_dir.join(format!("{}.nomatch", short_hash));
   if nomatch_target.is_file() {
       if let Ok(m) = nomatch_target.metadata() {
           if let Ok(modified) = m.modified() {
               if let Ok(elapsed) = modified.elapsed() {
                   if elapsed < Duration::from_secs(24 * 3600) {
                       return None;
                   }
               }
           }
       }
   }
   ```
   If OpenSubtitles finds no match, `nomatch_target` is written:
   ```rust
   let Some(dl) = download_url else {
       let _ = tokio::fs::write(&nomatch_target, b"no_match").await;
       return None;
   };
   ```
2. **`has_english_subtitles`:** Fast multi-source check:
   - Evaluates local directory sidecars (`list_tracks`).
   - Checks if online `.vtt` is already cached in `cache/subtitles/online/{short_hash}.vtt`.
   - Probes embedded container subtitle streams via `ffprobe`.
3. **`ensure_subtitles_for_movie`:** Proactively queries OpenSubtitles only if `has_english_subtitles` is `false`.

### B. Native Scanner Engine Integration (`rust/src/scanner/engine.rs`)
1. **Ingestion Hook:** For each newly discovered/indexed movie:
   ```rust
   if SubtitleService::ensure_subtitles_for_movie(&path, &relative, &final_title, roots, &cache_dir_buf).await {
       report.subtitles_acquired += 1;
   }
   ```
2. **Polite Background Sweep (`proactive_subtitle_sweep`):**
   - Sweeps existing library movies in PostgreSQL missing English subtitles.
   - Throttles requests with a 500ms sleep between consecutive OpenSubtitles API calls.
   - Respects 24h `.nomatch` markers and skips files already providing local/embedded English subtitles.
3. **Telemetry:** Added `subtitles_acquired: usize` to `ScannerReport` and `ScanResponse`.

---

## 3. Verification & Test Outcomes

### A. Dedicated Subtitle Integration Tests (`rust/tests/subtitle_test.rs`)
Command: `cmd.exe /c "E:\MediaServer\scripts\cargo.bat test --manifest-path E:\MediaServer\rust\Cargo.toml --test subtitle_test"`
```text
running 5 tests
test test_scanner_report_telemetry_includes_subtitles ... ok
test test_negative_match_cache_fast_path ... ok
test test_ensure_subtitles_skips_when_english_present ... ok
test test_opensubtitles_hash_computation ... ok
test test_has_english_subtitles_detection ... ok

test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.41s
```

### B. Full Regression Suite
- `qr_auth_test`: 5/5 passed.
- `audit_log_test`: 7/7 passed.
- `user_progress_test`: 4/4 passed.
- `admin_auth_test`: 6/6 passed.
- `api_contracts_test`: 4/4 passed.
- `probe_android_api.py`: 22/22 endpoints passed.
- `web/` vitest suite: 336/336 tests passed across 46 test files.

### C. Live Production Service Probing
- Production release binary built (`cargo build --release`).
- Service restarted cleanly via `scripts/restart_rust_service.ps1`.
- Live API response: 33 catalog movies verified online; SPA 200 OK.
