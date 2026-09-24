# Project Status, Completed Work, Bugs & Hosting Requirements

Last reviewed: 2026-09-24
Repository: `anis7t/media-server`
Working branch: `feat/flutter-production-player`

---

## Flutter Client Migration (active — read before touching `flutter_client/`)

Full handoff document: **[`docs/FLUTTER_CLIENT_STATUS.md`](FLUTTER_CLIENT_STATUS.md)**

| Phase | Title | Status |
|-------|-------|--------|
| 1 | Flutter Client Foundation | ✅ Committed (`5b0b1fa`, `eadb257`) on `feat/flutter-player-poc` |
| 2 | Video Player POC | ✅ COMPLETE — All 6 stages (2A–2E + 2F Acceptance Report) PASS on LAN & WAN (`f8e8c23`) |
| 3A | Production Player Architecture | ✅ COMPLETE — Committed on `feat/flutter-production-player` |
| 3B | Android-First Timeline & Live Seek Preview | ✅ COMPLETE — Committed (`2e95246`) |
| 3C | Audio & Subtitle Track Selectors, Speed & Controls Polish | ✅ COMPLETE — 58/58 tests passed, zero analyzer issues |
| 4 | Library Browsing & Media Ingestion UI | ⏳ Next up |

---

## 0. Recent work

### 2026-09-24 — Phase 3C: Audio & Subtitle Track Selectors, Playback Speed, & Controls Polish

- **Android-First Modal Sheets:**
  - Added `PlaybackSpeedSheet` for variable rate playback (0.5×–2.0×) with \(\ge 52\)dp touch targets.
  - Added `AudioTrackSheet` for live multi-audio track switching with channels, codec, and language tags.
  - Added `SubtitleTrackSheet` supporting subtitle disable, demuxed embedded streams, and sidecar WebVTT files via `GET /api/subtitles/<path:filename>` (`EXT` badge indicator).
- **Controls & HUD Polish:**
  - Integrated `PlayerHudToast` transient HUD pill for instant state feedback (speed, volume, mute, seek, subtitles).
  - Replay `↺` button for instant restart to `0:00`.
  - Responsive mobile clamping: volume slider automatically hidden on compact widths (< 620dp) where hardware buttons govern volume.
  - System back navigation handled via `PopScope`, exiting native fullscreen, aborting cancel tokens, stopping playback, and preventing timer leaks.
- **Verification:**
  - Automated tests: **58 / 58 tests passed** across `flutter test`.
  - Static analysis: **0 issues found** via `flutter analyze lib test`.

### 2026-09-24 — Waitress process-inspection optimization (~240x speedup) & Android native media_kit setup

- **Root Cause of Unbrowsable / Timeout Behavior:**
  On Windows, `find_ffmpeg_info_for_path()` called `psutil.process_iter(['pid', 'name', 'cmdline'])` eagerly querying `cmdline` across every running system process (~2.1s per invocation). In `get_active_transcodes()`, this ran sequentially for every video file needing transcoding (~10 files), locking Waitress worker threads for 21–25 seconds per full HTML render (`/`, `/movie/<filename>`, `/watch/<filename>`).
  With 8 Waitress worker threads, concurrent browser requests caused task queue depth warnings (`Task queue depth is 33`) and triggered `"The operation has timed out"` on any client/health probe with standard 4–6s timeouts.
- **Resolution:**
  1. Implemented `get_active_ffmpeg_processes()` in `app/services/transcode_service.py` filtering by process name (`'ffmpeg' in name`) *before* accessing command-line memory (`proc.cmdline()`).
  2. Batched inspection in `get_active_transcodes()` to query active FFmpeg processes once per cycle rather than once per video file, immediately skipping remaining files if no FFmpeg process is running.
  3. Increased `WAITRESS_THREADS=16` in `.env` for expanded concurrent range streaming headroom.
  4. Benchmark: `get_active_transcodes()` reduced from 21.0s to **0.088s** (~240× speedup).
  5. Test suite verification: **226 / 226 tests passed** (0 failures).
- **Android Physical Device Runtime Setup:**
  Integrated `media_kit_libs_android_video: ^1.3.8` to provide native `libmpv.so` (arm64-v8a) on Android 16 / SDK 36 for the Vivo I2217 physical test device. Verified clean `MediaKit.ensureInitialized()` runtime lifecycle.


### 2026-09-22 — root cause found: segment-index collision between chunks (content loss)

**Correction to the first version of this entry.** It claimed the AMF encoders "mislabel" the first
segment of every chunk and that a measurement-based label rewrite fixed it. That was wrong, and
the "99.88 %" repair of the Spider-Man playlist was actively harmful: ffmpeg's `#EXTINF` labels are
**honest** (a segment labelled 2.4 s really holds 60 frames = 2.4 s at 25 fps). The label looked
short only because it was being compared against `ffprobe -show_entries format=duration`, which
includes the segment's **audio pre-roll** (measured 4.33 s container vs 2.4 s of video for the same
segment). Rewriting labels from that quantity inflated the playlist and hid the loss behind an
ENDLIST. The label-rewrite code (`measured_label_overrides`, `repair_playlist_labels`) has been
**removed**, and the playlist builder now deliberately keeps ffmpeg's labels.

- **The real defect: a 60 s chunk does not emit the 15 segments the plan assumes, and the dense
  index grid let it overwrite the next chunk.** The plan gives chunk N `start_seg =
  round(start/4)`, contiguous with chunk N+1. Measured with the real pipeline and the real AMF
  encoders, a 60 s chunk emits **15, 16 or 17** segments depending on source/GPU/driver (Vega 8
  and RX 560X differ; pinning `-g` to a 4 s GOP - 15 x 4.0 s on the Vega 8 - makes the RX 560X
  emit a **single 60 s segment**, so no encoder-side setting fixes it). When a chunk emitted an
  extra segment, its last segment was written at the **next chunk's first segment index**;
  whichever render finished last won, and ~1.25 s of the previous chunk's tail was destroyed at
  every overflowing boundary.
- **Live proof, exact match.** Of the ten caches, the nine whose chunks emitted exactly 15
  segments each have **0 packet gaps**; Spider-Man - the only cache with overflowing chunks
  (**16 segments x70, 17 x15 = 85**) - has exactly **85 gaps / 279.4 s / 6,900 frames missing**
  (independent packet-PTS inventory). The earlier "resume-from-wrong-labels" explanation was a
  symptom of the same dense grid, not the cause.
- **Fix: strided, collision-proof segment indices.** Each chunk owns
  `chunk_id x SEGMENTS_PER_CHUNK_STRIDE` (32), so an extra segment can never reach the next
  chunk whatever the encoder does. Everything that assumed dense indices was fixed:
  `plan_chunks`, `_chunk_output_ok` (fails a chunk that leaves its stride), `_update_master_playlist`
  (walked indices densely from 0 - it stopped at the first inter-chunk gap and silently dropped
  every later chunk; coverage read 50 % for a fully rendered 120 s source), `_hls_resume_point`'s
  playlist reconstruction, `chunk_content_holes`, and `chunk_content_deficits` (now measures a
  chunk's **own run** of segments, not a fixed 15, which made complete chunks look 1.25 s short).
- **Legacy caches are migrated, not thrown away.** `_prepare_cache_layout()` runs before the queue
  is planned: an intact dense cache (chunk playlists that do not overlap) is **renumbered onto the
  strided grid by renaming files and rewriting the playlists - no re-encode**, preserving hours of
  GPU work; a cache whose chunk playlists **overlap** has already lost the content at those
  boundaries and is cleared for a full re-render. Validated against the real caches via a
  same-volume copy/hardlink harness: 1656- and 1356-segment caches migrated with **0 missing
  playlist entries** and the live directories asserted unchanged; Spider-Man's overlapping layout
  was detected as unrepairable. `.seg_layout` (value `stride32`) marks a migrated cache.
- **No label rewriting anywhere.** `repair_understated_caches()` (maintenance worker) now only
  strips ENDLIST from a cache that is short of **frames**, so the pipeline re-renders it; a
  genuinely short cache must be re-rendered, never relabelled.
- **Kept from the first round** (all still correct): frame accounting as the sole content measure
  (`chunk_content_deficits`; `-1` = unknown, never empty), ENDLIST refused while any chunk is
  short, video-stream-end denominator for completeness, memoised segment probes with a 3 s
  freshness guard, serialised atomic playlist writes, the phantom-cache-key guard, and
  fail-closed orphan auditing.
- Tests: **218 passing**, including the strided plan, migration vs clear, per-chunk frame
  accounting, boundary-stride rejection, resume-from-label-sum, and "unknown frames are not a
  deficit".
- Tools added: `scripts/hls_frame_audit.py` (per-chunk frame accounting),
  `scripts/hls_pipeline_regression.py` (real pipeline over a synthetic source - expect "deficient
  chunks: 0", full frame total, 100 % coverage, ENDLIST),
  `scripts/hls_layout_migration_check.py` (migration validated against real caches, read-only),
  `scripts/hls_per_gpu_segments.py` (per-GPU segment counts / why the plan cannot be trusted), in
  addition to `hls_content_gap_inventory.py`, `hls_gop_matrix.py`, `final_verification_battery.py`,
  `snapshot_live_data.py`.


#### Live rollout findings (same day, after the first restart)

The fix behaved correctly on the real movie - a full heal on a copy of Spider-Man's cache
(detect -> clear -> re-render 137 chunks -> `rc=0`, **0 deficient chunks, 204,595 frames =
8183.8 s = exactly the source's count**, 2146 playlist entries / 0 missing, ENDLIST, live cache
byte-identical) - but going live surfaced two more defects, both now fixed and tested:

1. **Frame measurement ignored the cache's layout (introduced by this round).**
   `chunk_content_deficits()` walked *strided* windows on caches still on the *legacy dense* grid.
   Chunk N's overflow segment sits on chunk N+1's first index, so for most chunks the walk read a
   neighbour's 32 segments (over-counting) and for the last ones a near-empty tail - reporting
   **complete caches as missing 38.5 s / 24.2 s / 33.2 s / 34.2 s / 13.7 s** and stripping their
   ENDLIST (5 live caches: Coyote, I Want Your Sex, Lust Stories 3, Moana, The Invite). No content
   was lost - only the ENDLIST line was removed. Fixed by dispatching on
   `cache_uses_strided_layout()`: a dense cache is judged on its whole-cache frame total (one
   aggregate entry, `chunk_id` -1); per-chunk windows are used only where they are exact. Verified
   live: Coyote 38.5 s -> **0 s**, I Want Your Sex 13.7 s -> **0 s**. The 5 caches were restored
   with ENDLIST after re-measuring (`_restore_endlist.py`, backup + atomic write).
2. **The ENDLIST strip was never wired to a re-render.** `_is_hls_truly_complete()` is label-based
   and a frame-deficient cache's labels can still sum to 100 %, so the auto-transcoder called such
   a cache complete and skipped it - exactly why Spider-Man sat at 99.88 % after the label
   "repair" hid its 277.2 s gap. `repair_understated_caches()` now calls `ensure_hls_transcode()`
   for every cache with a real deficit (including one already stripped by an earlier pass), so the
   heal completes instead of stranding.

Lesson recorded in `AGENTS.md`: frame measurement must respect the layout, and stripping ENDLIST
is not a heal on its own.
### Incident investigated: mass transcode-cache deletion
- ~25.7 GB of `cache/hls` (9 directories, incl. the `Punjab.95.Satluj` cache) vanished around 15:45–15:46 while the service was running. **No media file was affected** (all 9 MKVs in `D:\Flicks` intact); the server rebuilt the caches automatically.
- Root-cause class identified in code: orphan detection was **fail-open**. `audit_orphaned_caches()` wrapped `video_paths()` in `try/except` and set `active_videos = []` on any exception, and skipped individual files whose cache key raised — so a transient error (e.g. `database is locked`; SQLite here has no WAL and no `busy_timeout` under 8 Waitress threads) marked *every* directory orphaned. Two automatic non-dry-run purges consume that result: `cleanup_cache_on_startup()` (every service start) and `cache-maintenance-worker` (every 2 hours). The log holds 92 historical `Purged orphaned cache directory` events including multi-GB ones (`3536856922`, `3041758276`, `2811899673` bytes), i.e. this failure mode is recurring, not new.
- Evidence limits: the app log had **no timestamps** (see below), so individual purge events could not be dated; no single purge of ~25 GB was logged, so the exact trigger of this instance remains unproven. The service was not restarted manually around the event.

### Safety fixes applied
- `audit_orphaned_caches()` now **fails closed**: enumeration exceptions, per-file cache-key failures, and "no videos found while cache directories exist" all set `degraded` + `degraded_reasons`, and the orphan lists are returned **empty** rather than complete.
- `purge_orphaned_caches()` **refuses to delete** when the audit is degraded (`refused: True`, `reason`), and skips directories holding `hls.progress`/`playlist.m3u8` written within `RECENT_CACHE_GRACE_SECONDS` (600 s) — previously a purge could delete a directory an FFmpeg worker was still writing, producing `failed to rename ... Operation not permitted` storms.
- `cleanup_cache_on_startup()` no longer purges orphans; it only clears `.part` files and enforces the transcode-cache cap. Opt in with `MEDIA_SERVER_PURGE_ON_STARTUP=1`.
- `run_production.py` configures logging with `force=True` and `%(asctime)s` — `create_app()`'s earlier `basicConfig` had won, so service logs carried no timestamps and incident timelines were unreconstructable.

### Resolved: the disappearances were caused by the test suite, not by the app or the OS
- **Root cause proven.** `cache/hls` was being deleted by `pytest` runs on this host. Cache isolation was done by rebinding Python attributes at import, and two other modules silently undo that:
  - `tests/test_app.py::MediaServerTests.tearDownClass` restores the environment and then calls `importlib.reload(app.config)`, so `app.config.CACHE_DIR` becomes the live `C:\MediaServer\cache` again;
  - `tests/test_selenium_multi_seek_coyote.py` then executes `app_module.CACHE_DIR = app_module.config.CACHE_DIR`, rebinding the app back to the live cache and defeating `tests/test_storage_retention.py`'s import-time patch.
  From that point the non-dry-run purge tests in `test_storage_retention.py` walked the **live** cache, treated every directory as orphaned (the "active" set is derived from a temporary `MEDIA_ROOT`), and deleted real transcodes.
- **Reproduced deterministically**, not inferred: a 1-second cache watchdog caught the suite deleting four real directories at 18:43:48 (`372fdd0e`, `512dd05c`, `71f81790`, `9bf62fc5` gone; `f3ec5869` shrunk 1826 → 262 MB) while test-created directories (`ActiveDualGpuPur…`, `orphan_hls_fakehash…`, `orphan_enum_error`) appeared **inside the live cache**. The service log has no purge line in that window, so the deletions were not the service's.
- This also accounts for the **17:27:52** loss of the 3.3 GB `c4d01521…` (Moana) directory: it coincided with a full-suite run, and no application purge was logged at that time.
- The **15:45** loss of ~25.7 GB is the *service-side* mechanism: `audit_orphaned_caches()` was fail-open, so a transient enumeration failure marked every directory orphaned and the automatic non-dry-run purges removed them (92 `Purged orphaned cache directory` events are in the log, including multi-GB ones). The suite shares the production database after `test_app`'s teardown reloads `app.config`, so DB contention from a concurrent test run is a plausible trigger — that part remains inference, but the fail-open path itself is proven and fixed.
- Corrections to earlier notes in this section: the deletions were **not** attributable to Storage Sense, `SilentCleanup`, Defender or the recycle bin (no events, no records, and the USN journals on `C:` cover only ~15 minutes so they cannot reach the incident). `RefreshCache` is a `\Flighting\OneSettings\` telemetry task, unrelated to disk cleanup. Kernel object-access auditing and 1-second cache watching were installed during the investigation and are what produced the proof.
- The `MEDIA_SERVER_PURGE_ON_STARTUP` recommendation is unaffected: relocating `cache/` to `D:` remains a reasonable hardening step, but it is no longer needed to explain or stop these losses.

### Test-suite isolation fix (2026-09-21)
- New `tests/conftest.py` gives the suite two independent protections:
  1. `pytest_runtest_setup` re-points `config.CACHE_DIR`, `POSTER_CACHE`, `BACKDROP_CACHE`, `SUBTITLE_CACHE`, `SUBTITLE_EMBEDDED_CACHE` and `SUBTITLE_ONLINE_CACHE` at a throwaway tree **before every test**, so no import-order accident or module reload can leave the live cache active, and it fails the test if the live cache is ever resolved;
  2. the removal primitives (`shutil.rmtree`, `os.remove`/`os.unlink`, `Path.unlink`, `Path.rmdir`) refuse any deletion inside the checkout's `cache/` tree with a loud `TEST ISOLATION VIOLATION` error.
- The rest of the environment (media root, database, archive) is intentionally left at the host's real configuration: the page-rendering tests assert against the template/CSS constants that `app/__init__.py` reads from `BASE_DIR`, and the library tests need the real media root.
- Verified: full suite **184 passed** with `cache/hls` byte-identical before and after (5 directories / 11 GB), zero watchdog events and zero violations; the guard's teeth were confirmed by a temporary probe that attempted to delete a planted file and directory inside the live cache and was refused both times.

 ### Second leak fixed: the suite also wrote into the live library and database
 - The upload fixtures in `tests/test_app.py` (`Upload_Test_Movie.2025.mp4` 22 bytes, `Mayday (2026).mkv` 23 bytes) were written into the real `C:\Flicks` library, because `app/config.py::_resolve_upload_dirs()` returns `MEDIA_ROOT` while pytest is running and no upload target is configured. Fixture rows also went straight into the production database — `Mock.mkv` (tmdb 999999) is inserted by `tests/test_app.py`, plus `RichMovie.2026.mp4` and `Moana.2016.mp4`.
 - `tests/conftest.py` now redirects the database, upload target/staging, archive and deleted directories onto the throwaway tree **through the environment before the app is imported**, so an `importlib.reload(app.config)` recomputes throwaway paths instead of live ones; `pytest_runtest_setup` re-asserts every cache, database and upload path before each test and fails the test if the live cache or the live database is ever resolved.
 - Verified after the change: library **35 files**, production database **18 rows** and live cache **11 dirs / 17,957 segments** all hash-identical before and after a full **186-test** run. The artefacts were then removed through the application's own `purge_media()` (files, stub HLS/transcode caches, subtitle cache, metadata and database rows), leaving **13** real movie rows.

 ### Playback duration honesty: report the video stream's end for HLS
 - `/api/media-info` used the container duration, so a mux whose audio/subtitles outlive the picture advertised a seek-bar tail that can never play — the same "83 % complete" wall as the transcode denominator bug, but on the player side. It now returns `_source_progress_duration(path)` (video stream's end) for HLS playback and keeps the container duration for direct play, where the browser's own timeline comes from the file.
 - Motivating case: `Punjab.95.Satluj.2026.1080p.WEBRip.DD+5.1.Atmos.x264-KIN.mkv` — the **video track ends at 8254.6 s** while audio (9839.04 s), both subtitle streams (9839.07 s) and the container (9839.07 s) run to 2:43:59, and TMDb gives the runtime as 164 min. The container matches the intended length, so the **video track itself is truncated**; the HLS cache is complete and faithful (2064 segments covering all 8254.6 s of picture), and playback correctly stops where the picture ends.


### Security finding (fixed): unauthenticated arbitrary file deletion via /api/media/delete
- `purge_media()` caught `safe_path()`'s `abort(404)` and fell back to `config.MEDIA_ROOT / filename`, then unlinked that path with no containment check. Because the Waitress service runs as **LocalSystem**, a traversal name let `POST /api/media/delete/<name>` delete **any file on the host**.
- Verified live before the fix: `..%5C..%5C..%5CMediaServer%5C<file>` returned `{"file_deleted": true}` for a file outside the library, the absolute-path variant deleted the same way, and the `..%5C..%5C..%5CWindows%5CSystem32%5Cdrivers%5Cetc%5Chosts` variant **removed the Windows hosts file** (restored from `hosts.rollback`; the exact pre-deletion content is not recoverable). There is still no authentication in front of this route.
- Fix: the fallback is accepted only when `_is_within_media_roots(candidate)` is true, otherwise the call returns `{'success': False, 'error': 'Unsafe or unknown media path'}`; the unlink itself is additionally gated on containment. Regression tests: `tests/test_media_delete_safety.py` (fail without the fix).

### Transcode completeness fix (container vs video duration)
- `source_video_duration()` measures the **video stream's end** (`ffprobe -read_intervals <midpoint>%+99999`, ~0.3 s, memoised per path/size/mtime) instead of trusting `format.duration`.
- `DualGPUTranscodeJob` plans chunks and validates coverage against that value. `cleanup_cache_on_startup`/`transcode_status` report it too.
- `_finalize()` writes `#EXT-X-ENDLIST` **only when coverage validates** (≥ `MIN_COVERAGE_RATIO`, 0.98 of video duration); a failed validation leaves an EVENT playlist plus `progress=error`, bounded by `MAX_VALIDATION_ATTEMPTS` (3) so the auto-transcoder cannot re-encode the same tail forever.
- Per-chunk underproduction detection: a chunk that exits 0 while rendering < `MIN_CHUNK_YIELD_RATIO` (0.5) of its expected duration retires that GPU for the job and the chunk is retried on a healthy worker.
- Motivating case: a WEBRip whose audio/subtitles run ~26 min past the last video frame (video ends 8254.6 s inside a 9839.1 s container) was scored 83.9 % complete forever — every tail chunk could only emit a zero-duration segment.

---

## 1. Executive summary

This is a Flask-based personal media server designed for LAN playback and remote access. The codebase has been substantially modularized from the earlier monolithic application into an `app/` package containing routes, services, utilities, configuration, and database code. The server supports direct media streaming, on-demand HLS transcoding, dynamic multi-GPU chunked transcoding, TMDb metadata, local subtitles, resumable uploads, library management, device telemetry, live playback telemetry, live video seek preview thumbnails, storage retention policies, automated orphaned cache governance, and Cloudflare Tunnel remote access.

The system is deployed on Windows 11 as persistent background Windows Services (`MediaServer` via NSSM and `Cloudflared`), surviving reboots without user login and supporting automatic crash recovery. Hardware transcoding is fully operational using dual AMD GPUs (Radeon RX 560X discrete + Radeon Vega 8 integrated).

---

## 2. Current repository architecture

### Application entry points

- `app.py` — lightweight executable entry point.
- `app/__init__.py` — application factory, route registration, and compatibility exports.
- `app/config.py` — environment-driven paths, limits, and runtime settings.
- `app/db.py` — SQLite connection, schema, and migration support.
- `run_production.py` — production WSGI entry point (Waitress on Windows, Gunicorn on Linux).

### HTTP routes

- `app/routes/pages.py` — HTML pages and page navigation (`/`, `/library`, `/details/<file>`, `/watch/<file>`, `/devices`, `/manage`).
- `app/routes/api.py` — JSON/API endpoints including devices, metadata, seek preview thumbnails, transcode progress, and playback state.
- `app/routes/media.py` — media streaming, RFC 7233 byte-range delivery, and HLS segment serving.
- `app/routes/subtitles.py` — local subtitle/WebVTT delivery and format conversion.
- `app/routes/upload.py` — resumable/chunked upload workflow with smoothed ETA.

### Services

- `chunk_transcode_service.py` — dynamic multi-GPU chunked transcoding engine dividing source media across multiple GPU workers.
- `gpu_service.py` — hardware GPU capability detection, adapter binding, and engine utilization telemetry.
- `transcode_service.py` — FFmpeg/HLS transcoding, hardware acceleration (AMF/VAAPI), caching, resume, and cleanup.
- `preview_service.py` — video seek hover preview thumbnail extraction and caching.
- `media_service.py` — media probing, paths, and media operations.
- `media_resolver.py` — automatic/forensic media identification and TMDb matching.
- `scanner_service.py` — library discovery and ingestion.
- `tmdb_service.py` — TMDb API integration.
- `subtitles_service.py` — subtitle discovery/conversion/processing.
- `device_service.py` — client/device identification, telemetry, heartbeats, and device history.
- `worker_service.py` — background worker coordination.
- `system_service.py` — system-level status/telemetry functionality and multi-GPU utilization reporting.

### Utilities

- `filesystem.py` — safe filesystem/path helpers.
- `formatting.py` — display formatting helpers.
- `subtitles.py` — subtitle parsing/conversion helpers.

---

## 3. Completed major work

### Multi-GPU chunked transcoding & hardware acceleration
- **Dual-GPU Utilization:** Treated discrete AMD Radeon RX 560X (`dx11:1` or Task Manager GPU 0) and integrated AMD Radeon Vega 8 (`dx11:0` or Task Manager GPU 1) as independent parallel transcoding workers.
- **Dynamic Chunk Scheduling:** Implemented keyframe-aligned chunk allocation across available GPUs, enabling both GPUs to transcode separate segments simultaneously.
- **Hardware Telemetry:** Multi-GPU utilization tracking via Windows Performance Counters / PyNVML exposed through `/api/system/stats` and displayed directly on the System Telemetry HUD.
- **Cadence Optimization:** Reduced transcode status polling interval to 1-second cadence for real-time progress, speed (fps/multiplier), and smoothed ETA calculations.

### Video seek hover preview thumbnails
- **Live Frame Previews:** Hovering over the YouTube-style seekbar renders an accurate, high-fidelity frame preview thumbnail extracted at the cursor's hover timestamp.
- **Dynamic Thumbnail Caching:** Implemented `preview_service.py` with fast keyframe extraction (`-ss` before `-i`) and server-side disk caching under `cache/previews/`.
- **Seamless Player Integration:** Updated seekbar JavaScript and CSS to position hover previews smoothly with boundary clamping across desktop and mobile screens.

### Windows persistent services & automatic startup
- **MediaServer Windows Service:** Registered Waitress WSGI server as an automatic Windows Service via NSSM. Operates independently of user login sessions, restarts automatically on crash, rotates logs at 10 MB (`logs/waitress.log`), and injects FFmpeg paths.
- **Cloudflared Windows Service:** Named Cloudflare Tunnel (`media.anisparvez.in`) operates as a persistent Windows Service with dynamic DNS overwrite capabilities.
- **Lifecycle Management Scripts:** Created `scripts/install_service.bat`, `scripts/uninstall_service.bat`, `scripts/restart_service.bat`, and `scripts/service_status.ps1`.

### Upload lifecycle UX hardening
- **Post-Upload Abort Concealment:** Immediately hides the Cancel/Abort button upon 100% byte upload completion (`offset >= total`), preventing client-side cancellation during backend ingestion.
- **Dynamic Cycling Ingestion Indicator:** Restored animated dynamic processing card showing cycling indexing labels (*Probing video stream...*, *Querying TMDb...*, *Caching posters...*, *Synchronizing subtitles...*).
- **Resumable & Smoothed ETA:** Chunked transfers with exponential moving average speed smoothing.

### Player UX & controls polish
- **Hold-to-Speed Removal:** Completely removed hold-to-accelerate (2×) gesture from player pointer events and removed its entry from `#shortcutsModal` while preserving the standard speed dropdown.
- **Dark Mode Native Selects:** Fixed broken white-on-white dropdown popups on Windows Chromium by applying `color-scheme: dark !important;` and custom dark option backgrounds to `#speed` and `#controls select`.
- **Control Button Focus Boundary:** Added vertical padding (`padding: 4px 0 !important;`) to `.controls-row` to prevent hover lift (`translateY(-1px)`) and focus outlines from getting truncated at the top boundary.
- **Circular Geometries & Icon Prominence:** Enforced uniform 36px circular button geometries and enlarged SVG icons from 18px to 21px for touch and desktop accessibility.
- **Continue Watching Rail:** Compacted carousel cards to 140px width on desktop (115px on mobile) with sub-scroll gesture isolation (`overscroll-behavior-x: contain; touch-action: pan-x;`).

### Core library, media & subtitle features
- Direct byte-range streaming for MP4/M4V/WebM media with zero-copy RFC 7233 delivery.
- On-demand HLS transcoding for MKV/HEVC with cache resume and cleanup.
- **In-Progress Transcode HLS Timeline Synchronization:** Enforced `#EXT-X-START:TIME-OFFSET=0` and `#EXT-X-PLAYLIST-TYPE:EVENT` during active chunked transcoding, monotonic `-output_ts_offset` preventing PTS resets, and dynamic `#EXTINF` duration parsing to resolve timeline drift and mid-stream stalling.
- **Subdirectory Subtitles & Language Auto-Detection:** Resolved Werkzeug route collision (`<path:filename>/<name>`) for media in subdirectories, and integrated `detect_subtitle_language()` heuristic for local `.srt`/`.vtt` content language classification and local default precedence over OpenSubtitles.
- **Purge Worker Termination Safety:** Thread-safe chunk worker tracking (`DualGPUTranscodeJob.get_active_pids()`) and process self-termination guards ensuring background FFmpeg workers terminate cleanly without affecting the server process.
- **Periodic (4-Hour) TMDb Metadata Refresh & Manual Scan Trigger:** Implemented automated daemon worker (`metadata-refresh-worker`) in `worker_service.py` to refresh TMDb metadata (ratings, vote averages, runtime, tagline, certifications, cast, artwork) every 4 hours, added `last_metadata_refresh` schema migration in SQLite, and synchronized manual UI "↻ Scan" trigger to refresh both filesystem additions and existing metadata.
- **Server-Wide Manual Subtitle Upload with Language Auto-Detection:** Built full subtitle upload interfaces on `/movie/<filename>` and directly inside the in-player Subtitle Settings modal (`#subSettingsModal`). Auto-detects subtitle language from content text via script heuristics and stop-word frequency analysis, persisting files in canonical format `<short_movie_name>_<detected_language>_<incremental_number>.<ext>` alongside media, with dynamic `<track>` DOM creation and track dropdown selection without requiring page reload or interrupting playback.
- Local `.srt` and `.vtt` discovery, delivery, and in-memory WebVTT conversion with dual-axis positioning (horizontal and vertical elevation).
- **Cross-Root Mirror Subtitle Discovery & Route Authorization:** Enhanced `tracks()` in `subtitles_service.py` and `subtitle()` in `routes/subtitles.py` to resolve mirror subdirectories across all active media roots (stripping `.archive` prefix paths), ensuring original sidecar subtitles residing in primary roots are automatically discovered and authorized for playback when media is archived to secondary volumes (e.g. *The Odyssey*).
- **HLS Seeking Stabilization & Snapback Elimination:** Guarded `jumpStartGap()` and seek/transcode event listeners in `templates/player.html` against in-flight user scrubbing (`isScrubbingNow()`), native seek requests (`v.seeking`), and active seek targets (`currentSeekTarget !== null`), while suppressing redundant transcode progress polling once streams are 100% cached, resolving seeking stalls and unintended jumps back to `0:00`.
- TMDb metadata resolution with forensic filename identification.
- Connected device telemetry dashboard (`/devices`) with Chromium High-Entropy Client Hints, network classification, and heartbeats.
- Technical Stats for Nerds HUD (`n` / `N` key) reporting dropped frames, viewport resolution, forward buffer, and stream state.

---

### Post-transcode storage retention & safe orphaned cache purge
- **Configurable Retention Policies:** Implemented user-configurable post-transcode retention policies (`keep`, `archive`, `delete_source`) persisted in the `settings` database table. Default `'keep'` guarantees non-destructive operation, `'archive'` moves original source files to `D:\Flicks\.archive` (preserving primary SSD headroom while leveraging high-capacity secondary storage), and `'delete_source'` **moves the uploaded raw file to a `.deleted` staging area** (`D:\Flicks\.deleted`) to reclaim 100% of the raw file space while preserving the completed HLS stream and library metadata so files never require re-transcoding. The source file is recoverable from the staging area until manual cleanup.
- **Zero-Byte Corruption Fix:** Fixed critical bug where `delete_source` policy truncated source files to 0 bytes, causing `video_paths()` to rediscover them and trigger infinite re-transcoding loops that overwrote valid HLS caches. Added defensive size check in `is_video()` (`p.stat().st_size > 0`) and changed `apply_post_transcode_policy()` to move files to `.deleted` staging instead of truncating.
- **HLS Cache Preservation Fix (ENDLIST Authoritative):** Fixed `_is_hls_truly_complete()` to treat any playlist with `#EXT-X-ENDLIST` as complete, regardless of EXTINF duration sum accuracy. Previously, caches with ENDLIST but mismatched EXTINF durations (< 90% source duration) were incorrectly flagged incomplete and purged by `audit_orphaned_caches()`. Now ENDLIST (the authoritative FFmpeg completion signal) is trusted absolutely, preventing loss of valid completed transcodes.
- **Automated Orphaned Cache Auditing:** Implemented `audit_orphaned_caches()` in `transcode_service.py` to reconcile all directories under `cache/hls/` and `cache/previews/` against active video paths and in-flight transcodes. Hardened active mapping to track canonical `hls_cache_dir()` and `preview_dir()` directories rather than whole candidate sets, allowing obsolete duplicates and partial transcode stubs to be detected and reclaimed.
- **Safe Orphaned Cache Purge Engine:** Built `purge_orphaned_caches(dry_run=False)` with bounded Windows file-lock retry semantics (`_remove_path_with_retries`), automatically executed during server startup (`cleanup_cache_on_startup`) and by background daemon worker every 2 hours (`cache-maintenance-worker`). Reclaimed redundant duplicate transcode artifacts (3.55 GB), reducing transcode cache footprint from 17.0 GB to 13.7 GB across all 5 library titles.
- **REST API Endpoints:** Added `/api/storage/audit`, `/api/storage/purge-orphans`, `/api/storage/settings`, and `/api/storage/archive/<filename>` with input validation and dry-run preview support.
- **Management UI & Governance Dashboard:** Enhanced `/manage` with Storage Retention & Cache Governance card showing host storage pool utilization, interactive retention policy selector with instant persistence toast, real-time orphaned cache counter badge, clean orphaned caches confirmation modal (`#cleanOrphansModal`), and per-item source archiving action. Bounded `.sc-policy-select` within card boundaries (`min-width: 0`, `max-width: 100%`, `text-overflow: ellipsis`) preventing horizontal blowout.
- **Desktop Search Header & Mobile Player Controls Polish:** Expanded desktop header form layout (`flex: 1 1 200px`, `max-width: 58rem`) ensuring the library searchbox remains wide and prominent. Corrected CSS specificity cascade on `#controls button` by removing `!important` from `display: inline-flex` and enforcing mobile-only hiding of secondary controls (`#volume`, `#skipBackBtn`, `#skipForwardBtn`, `#shortcutsBtn`, `#mute`, `#restartBtn`, `#pipBtn`, `#nerdStatsBtn`), ensuring the `#rotateBtn` is fully visible and accessible on mobile viewports alongside Play, Speed, CC, and Aspect Ratio. Added responsive horizontal scroll isolation to `.player-header-actions` on mobile.

### Dual-drive storage tiering & cross-volume cache resilience
- **Tiered Drive Architecture:** Tiered the media server across fast primary NVMe SSD (`C:`) and high-capacity secondary volume (`D:`):
  - **Fast NVMe SSD (`C:`):** Hosts the OS, Waitress WSGI server, SQLite database (`media.db`), in-progress transcode scratch, seek-preview thumbnails (`cache/previews`), and completed multi-GPU HLS stream segments (`cache/hls`) for zero-stutter RFC 7233 delivery.
  - **Mass Secondary Volume (`D:`):** Hosts raw media library storage (`D:\Flicks`), resumable upload staging (`D:\Flicks\.uploads`), and cold original file archives (`D:\Flicks\.archive`).
- **Multi-Root Dynamic Media Discovery:** Implemented `config.get_media_roots()` returning all active roots (`[MEDIA_ROOT, UPLOAD_TARGET_DIR, ARCHIVE_DIR]`). Updated `video_paths()`, `safe_path()`, `movie()`, and `poster_for()` to discover and serve media seamlessly regardless of which configured drive volume it resides on.
- **Cross-Volume Cache Key Continuity:** Enhanced `hls_cache_dir()` and `preview_dir()` to compute relative paths against alternative roots (`root / rel`). When media files move across volumes (e.g. `C:` to `D:`), their cache keys remain 100% deterministic and active, preventing cache invalidation, playback 404s, or false-positive orphaned directory deletion.
- **Cross-Volume Subtitle Discovery & Authorization:** Updated `tracks()` in `subtitles_service.py` to compute relative filenames against all active roots and search both `path.parent` and `config.MEDIA_ROOT` for sidecar `.srt`/`.vtt` files. Hardened `/subtitles/<path:filename>/<name>` to verify filesystem authorization across all configured media roots.
- **Host Headroom Reclaimed:** Reclaimed over **24.2 GB of SSD space** on `C:`, increasing free headroom from 14.3 GB to **38.59 GB** while all 4 library titles (*Coyote vs. Acme*, *Moana*, *Star Wars*, *The Odyssey*) remain fully playable with complete subtitle coverage.
- **Multi-Chunk HLS Discontinuity Alignment & Monotonic Timestamp Preservation:** Eliminated playback resets to `0:00` during forward seeking across chunk boundaries on transcoded media (*Coyote vs. Acme*). Removed `-avoid_negative_ts make_zero` in `chunk_transcode_service.py` ensuring `-output_ts_offset` preserves timeline timestamps, integrated RFC 8216 `#EXT-X-DISCONTINUITY` insertion between chunk boundaries in `_update_master_playlist()`, and added automatic on-the-fly disk playlist reconciliation (`reconcile_hls_playlist_discontinuities()`) in `app/routes/media.py`. Hardened `templates/player.html` error listeners to preserve seek positions on fallback. Verified via 163-test pytest suite, Selenium forward-seek test, and live Chrome DevTools MCP inspection with zero `DEMUXER_ERROR_COULD_NOT_PARSE` events.

### Unified navigation header, custom select pickers & mobile rail polish
- **Frosted Obsidian Glass Header:** Redesigned top navigation header across all 5 primary pages (`/`, `/movie/<filename>`, `/player/<filename>`, `/manage`, `/devices`) with frosted glass background (`rgba(11, 15, 23, 0.88)` with `backdrop-filter: blur(24px)`), translucent border, and ambient shadow.
- **3D Glossy Play Brand Identity:** High-fidelity vector SVG brand icon with multi-stop crimson linear gradients, radial specular highlights, and ambient drop shadows, paired with two-tone typography (**Anis'** + **Home Media Server**) and brand subtitle (**PLAY • ORGANIZE • ENJOY**).
- **Responsive Mobile Action Rail:** Replaced non-functional hamburger menus on mobile viewports (\(\le 768\text{px}\)) with touch-friendly, horizontal swipeable action rails (`overscroll-behavior-x: contain; touch-action: pan-x; -webkit-overflow-scrolling: touch;`), allowing instant single-tap access to primary actions.
- **Desktop & Mobile Search Density Polish:** Completely removed the redundant A-Z sort dropdown across both desktop and mobile views in favor of natural library browsing and direct search input filtering.
- **Home Page Section Hierarchy (Telemetry at Footer):** Repositioned the System Telemetry HUD (`#systemTelemetryCard`) to the footer of the home page (strictly after "All Movies"), prioritizing user media and continue-watching cards while keeping technical stats accessible at the bottom.
- **Universal Top-Layer Customizable `<select>` Popovers:** Adopted modern Customizable Select API (`appearance: base-select` and `select::picker(select)`) to replace sharp, bright blue Windows system menus with top-layer frosted obsidian glass popovers (`rgba(18, 22, 32, 0.96)`, `backdrop-filter: blur(24px)`), rounded corners (`12px`), brand red active highlights (`#e50914`), white checkmarks (`select option::checkmark`), and smooth rotating chevrons (`select:open::picker-icon`). Applied universally across `/manage` storage retention policy, playback speed (`#speed`), and in-player subtitle settings modal dropdowns.
- **Chromium Hls.js Precedence Invariant:** Enforced `window.Hls && Hls.isSupported()` precedence over native `canPlayType` before falling back in `templates/player.html`. Resolves broken multi-chunk discontinuity seeking on Windows Chromium browsers where `canPlayType` evaluates to `"maybe"` (truthy) but cannot demux multi-chunk timeline offsets. Verified via automated Selenium multi-seek test across 5 seek points (60s, 180s, 360s, 450s, 600s).
- **Mobile Player Controls Expansion & Dedicated Seekbar Spacing:** Restored primary player controls (`↺` Restart, `▶`/`⏸` Play, `🔊` Mute, `1×` Speed, `CC ⚙` Subtitles/Settings, Aspect Ratio, Rotate Screen, PiP, Nerd Stats) on mobile viewports within a swipeable non-overflowing rail (`overflow-x: auto`), cleanly hid desktop-only controls (`#volume` and `#shortcutsBtn`), explicitly hid redundant `-10s`/`+10s` buttons on mobile in favor of seekbar/double-tap gestures, and eliminated the dead space between `.seek-time-row` and seekbar (`margin-bottom: -9px !important`).
- **Unified "Anis' Home Media Server" Branding & In-App User Manual:** Standardized brand identity across all pages to **Anis' Home Media Server** with fluid clamp typography preventing text wrapping or horizontal clipping on compact mobile devices (320px–480px). Implemented comprehensive in-app User Manual (`/manual`) with quick category navigation pills, full shortcut cheatsheet, multi-GPU streaming explanations, and added "How to use" link across all site footers. Authored offline markdown manual (`docs/MANUAL.md`).


---

## 4. Next steps & active roadmap

### Secondary / parked
1. **Automatic OpenSubtitles behavior:** local subtitles work; incorrect automatic OpenSubtitles behavior is parked.
2. **Authentication/access control:** the stable Cloudflare hostname is not authentication. Add access control before wider public sharing.
3. **Cloudflare media-delivery architecture:** review current Cloudflare service-specific video/large-file policies before treating the public tunnel/CDN path as a scalable distribution system.
4. **Production concurrency tuning:** benchmark any change to worker or thread pools. Remote capacity is primarily constrained by ISP upload bandwidth and tunnel/network latency.

---

## 5. Platform requirements

### Windows hosting (Current production workstation)
- Windows 10/11 or supported Windows Server.
- Python 3.14.3 in virtual environment `C:\MediaServer\venv`.
- Dual AMD GPUs: Radeon RX 560X (discrete) + Radeon Vega 8 (integrated).
- FFmpeg 9.0.1 essentials build with AMF & D3D11va support.
- NSSM (Non-Sucking Service Manager) for persistent WSGI hosting (`MediaServer`).
- Cloudflared 2026.9.1 running as an automatic Windows Service (`Cloudflared`).

### Linux / Kali / Debian-family hosting
- Python 3.10+; current development uses Python 3.14.x.
- `pip` and `venv`.
- FFmpeg and FFprobe on `PATH`.
- Production WSGI: Gunicorn with `gthread` worker class (1 worker, 8 threads).
- Systemd service with user lingering enabled.
- Cloudflared named tunnel for remote access.

---

## 6. Testing & verification protocol

Before committing or deploying changes:

```powershell
# Compile validation
python -m py_compile app/config.py app/services/transcode_service.py app/services/chunk_transcode_service.py app/services/gpu_service.py

# Full automated test suite (164 tests)
.\venv\Scripts\python.exe -m pytest tests/
```

Manual playback & telemetry verification:
1. Direct MP4/AAC playback (`Oculus`, `Spider-Man`).
2. MKV/HEVC HLS playback (`The Odyssey`, `Moana`).
3. Seek to `0:00` and arbitrary timestamps.
4. Hover seekbar to verify live frame thumbnail previews.
5. System Telemetry HUD displays active GPU engine utilization.
6. Storage Retention & Cache Governance card on `/manage` reports accurate cache and storage telemetry.
7. Verify no mobile horizontal or vertical layout overflow.

---

## 7. Immediate work queue

1. **Production Concurrency Tuning & Benchmarking:** Benchmark worker and thread pools against remote stream latency and Cloudflare tunnel limits.
