# Agent Instructions — Anis' Media Server

## 1. Project identity and source of truth

- Repository: `anis7t/media-server`
- Framework: **Flask**, not Django.
- The application is modularized under `app/` with routes, services, utilities, configuration, and database layers.
- Root `app.py` is intentionally a lightweight executable entry point; `app/__init__.py` owns the application factory and compatibility exports.
- `docs/PROJECT_STATUS.md` is the primary current handoff: it records completed work, known bugs, platform requirements, testing requirements, and the immediate work queue. Read it before substantial changes.
- `docs/DEVELOPMENT_STATUS.md` and `docs/WINDOWS_SETUP.md` contain the detailed current Windows/AMF and persistent service state. `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md` contains the remote-access history and named-tunnel configuration.
- `docs/MULTI_GPU_CHUNKED_TRANSCODING_PROPOSAL.md` documents the dynamic multi-GPU chunked transcoding architecture implemented in `app/services/chunk_transcode_service.py` and `app/services/gpu_service.py`.

## 2. Current architecture

```text
Browser / Client
  -> Cloudflare named tunnel: media.anisparvez.in
  -> http://127.0.0.1:8000
  -> Waitress WSGI (NSSM Windows Service)
  -> Flask routes / API
  -> services
     -> SQLite (media.db)
     -> local media/artwork/subtitle storage (C:\Flicks)
     -> FFmpeg/FFprobe dual-GPU chunked transcoding
        -> AMD Radeon RX 560X (discrete, dx11:1)
        -> AMD Radeon Vega 8 (integrated, dx11:0)
     -> Live frame preview cache (cache/previews/)
     -> TMDb API
```

Important modules:

- `app/config.py` — environment-driven paths and runtime settings.
- `app/db.py` — SQLite/schema/migrations.
- `app/routes/pages.py` — HTML pages.
- `app/routes/api.py` — API/device/playback/seek-preview endpoints.
- `app/routes/media.py` — byte-range media delivery and HLS segments.
- `app/routes/subtitles.py` — local subtitle/WebVTT delivery.
- `app/routes/upload.py` — resumable chunked uploads.
- `app/services/chunk_transcode_service.py` — dynamic multi-GPU chunk scheduler.
- `app/services/gpu_service.py` — GPU detection and live engine telemetry.
- `app/services/preview_service.py` — live seek hover frame extraction & caching.
- `app/services/media_service.py` — media probing/path operations.
- `app/services/media_resolver.py` — multi-source/forensic media identification.
- `app/services/scanner_service.py` — library ingestion.
- `app/services/tmdb_service.py` — TMDb integration.
- `app/services/transcode_service.py` — FFmpeg/HLS transcoding, cache/resume/cleanup.
- `app/services/subtitles_service.py` — subtitle processing.
- `app/services/device_service.py` — device telemetry/heartbeats/history.
- `app/services/worker_service.py` — background work coordination.
- `app/services/system_service.py` — system telemetry and multi-GPU utilization stats.

## 3. Completed capabilities

The current project includes:

- **Direct Play:** Zero-copy RFC 7233 byte-range playback for MP4/M4V/WebM.
- **Dynamic Multi-GPU Transcoding:** Concurrent chunk-based encoding across discrete AMD Radeon RX 560X (`dx11:1`) and integrated AMD Radeon Vega 8 (`dx11:0`).
- **Live Multi-GPU Telemetry:** Real-time hardware engine utilization tracking via Windows Performance Counters and PyNVML displayed on the System Telemetry HUD.
- **Live Seek Hover Previews:** Frame thumbnails extracted on-demand via `preview_service.py` and cached in `cache/previews/`.
- **1-Second Transcode Cadence:** High-frequency status polling for smooth progress bars, fps/speed reporting, and smoothed ETA calculations.
- **Windows Persistent Services:** `MediaServer` (Waitress via NSSM) and `Cloudflared` run as automatic Windows Services surviving reboots without user login, with crash auto-restart and 10 MB log rotation.
- **Upload Lifecycle Hardening:** Immediate Abort button concealment upon 100% upload completion and animated dynamic processing card showing cycling background indexing stages.
- **Player Controls Polish:** Removed hold-to-speed-up gesture, cleaned shortcuts cheat-sheet modal, native dark scheme select dropdowns (`color-scheme: dark !important;`), uniform 36px circular buttons, prominent 21px SVG icons, and 4px controls-row padding preventing top focus clipping.
- **Carousel Optimization:** Compacted "Continue watching" rail cards to 140px desktop / 115px mobile.
- **Dual-Axis Subtitles:** Horizontal alignment plus lowered/bottom/raised/middle/top vertical positions with playback-control cue elevation.
- **Connected Devices Dashboard:** Chromium High-Entropy Client Hints, network path detection, active/offline states, friendly renaming, and watch history.
- **In-Progress Transcode HLS Synchronization:** Enforced `#EXT-X-START:TIME-OFFSET=0` and `#EXT-X-PLAYLIST-TYPE:EVENT` during active chunked transcoding, monotonic `-output_ts_offset` preventing PTS resets, and dynamic `#EXTINF` duration parsing to resolve timeline drift and mid-stream stalling.
- **Subdirectory Subtitles & Language Auto-Detection:** Resolved Werkzeug route collision (`<path:filename>/<name>`) for media in subdirectories, and integrated `detect_subtitle_language()` heuristic for local `.srt`/`.vtt` content language classification and local default precedence over OpenSubtitles.
- **Purge Worker Termination Safety:** Thread-safe chunk worker tracking (`DualGPUTranscodeJob.get_active_pids()`) and process self-termination guards ensuring background FFmpeg workers terminate cleanly without affecting the server process.
- **Periodic (4-Hour) TMDb Metadata Refresh & Manual Scan Trigger:** Background scheduler (`metadata-refresh-worker`) in `worker_service.py` refreshing TMDb details (ratings, vote averages, runtime, tagline, cast, certification, artwork) every 4 hours, SQLite `last_metadata_refresh` schema migration, and synchronized manual UI "↻ Scan" trigger re-synchronizing metadata alongside newly discovered files.
- **Server-Wide Manual Subtitle Upload with Language Auto-Detection:** Subtitle upload interface on movie details (`/movie/<filename>`) and integrated directly inside the in-player Subtitle Settings modal (`#subSettingsModal`). Auto-detects subtitle language from content text (Unicode character analysis & NLP heuristic), saving files server-wide alongside media in the canonical format `<short_movie_name>_<detected_language>_<incremental_number>.<ext>` with dynamic in-player `<track>` insertion and zero playback disruption.
- **Post-Transcode Storage Retention & Safe Orphaned Cache Purge:** User-configurable retention policies (`keep`, `archive`, `purge_cache`) persisted in the `settings` database table, automated cache reconciliation (`audit_orphaned_caches()`), safe Windows-lock-resilient orphaned purge (`purge_orphaned_caches()`), background daemon worker (`cache-maintenance-worker`), REST API suite (`/api/storage/*`), and interactive management UI with storage pool telemetry and one-click orphan cleaning.
- **Dual-Drive Storage Tiering & Cross-Volume Cache Resilience:** Tiered architecture leveraging primary fast NVMe SSD (`C:`) for OS, SQLite, in-progress transcode scratch, and completed HLS cache (`cache/hls`), while offloading cold raw media, resumable upload staging, and source archives to secondary drive (`D:\Flicks`, `D:\Flicks\.archive`). Includes dynamic multi-root discovery (`get_media_roots()`), cross-volume relative-path cache key preservation in `hls_cache_dir()` and `preview_dir()`, and cross-volume sidecar subtitle resolution and authorization.
- **Cross-Root Mirror Subtitle Discovery & HLS Seeking Stabilization:** Subtitle engine automatically discovers sidecar `.srt`/`.vtt` files across mirror subdirectories in any configured media root (stripping `.archive` paths) for archived media (e.g. *The Odyssey*), and player seeking event handlers guard `jumpStartGap()` and `checkPreparing()` against in-flight user scrubbing and active seeks, eliminating playback stalls and `0:00` resets.
- **Unified Navigation Header & Brand Identity:** Redesigned frosted obsidian glass header with 3D glossy play SVG brand icon, two-tone typography (**Anis'** + **Home Media Server**), subtitle (**PLAY • ORGANIZE • ENJOY**), modular SVG pill buttons, and responsive horizontal swipeable action rails across all pages (`/`, `/movie/<filename>`, `/player/<filename>`, `/manage`, `/devices`, `/manual`).
- **Universal Customizable `<select>` Popovers:** Modernized dropdown pickers using `appearance: base-select` and `select::picker(select)` across `/manage`, playback speed, and subtitle settings with obsidian glass styling and brand red active highlights.
- **Library Navigation Density & Hierarchy:** Removed redundant A-Z sort dropdown across desktop and mobile, and repositioned System Telemetry HUD to the bottom of the home page (strictly after "All Movies"), prioritizing library browsing.
- **Mobile Player Controls Expansion & Dedicated Seekbar Spacing:** Restored primary controls (`↺` Restart, `🔊` Mute, `1×` Speed, `CC ⚙` Subtitles/Settings, Aspect Ratio, Rotate Screen, PiP, Nerd Stats) on mobile inside a swipeable non-overflowing rail, cleanly hid redundant desktop-only buttons (`#volume`, `#shortcutsBtn`, and `-10`/`+10` seek buttons), and eliminated vertical gap between `.seek-time-row` and seekbar (`margin-bottom: -9px !important`).
- **Interactive User Manual & Footer Navigation:** Added in-app User Manual (`/manual`) with full shortcuts cheatsheet, touch gestures, multi-GPU streaming guide, and footer "How to use" link. Authored offline user guide in `docs/MANUAL.md`.


## 4. Known unresolved issues & active roadmap

### Highest priority — immediate work queue

1. **Production concurrency tuning & remote streaming benchmarks:**
   Benchmark Waitress worker and thread pools against remote stream latency, Cloudflare tunnel limits, and concurrent client playback.

### Secondary / parked

4. **Automatic OpenSubtitles behavior:** local subtitles work; incorrect automatic OpenSubtitles behavior is parked.
5. **Authentication/access control:** the stable Cloudflare hostname is not authentication. Add access control before wider public sharing.
6. **Cloudflare media-delivery architecture:** review current Cloudflare service-specific video/large-file policies before treating the public tunnel/CDN path as a scalable distribution system.
7. **Production concurrency tuning:** benchmark any change to worker or thread pools. Remote capacity is primarily constrained by ISP upload bandwidth and tunnel/network latency.

## 5. Platform/dependency rules

### Windows
- Windows 10/11 or supported Windows Server.
- Python 3.10+; current tested host uses Python 3.14.3.
- PowerShell, Git, FFmpeg and FFprobe.
- Production WSGI: **Waitress**, not Gunicorn.
- Remote access: `cloudflared.exe` Windows Service.
- Never use `os.kill(pid, 0)` to check process liveness on Windows; use `app.services.transcode_service.is_pid_alive(pid)` (exported in `app`) to avoid broadcasting `CTRL_C_EVENT` across the console group.
- Never use `os.rename()` across disk volumes on Windows; use `shutil.move()` with target collision pre-unlinking.
- In tests and cache audits, always call `get_cache_dir()` rather than referencing `app.config.CACHE_DIR` directly, as test harnesses patch `app.CACHE_DIR`.
- Prioritize secondary high-capacity drives (`D:\Flicks`, `D:\Flicks\.archive`) for raw video files, upload staging (`D:\Flicks\.uploads`), and cold source retention, preserving primary OS SSD (`C:`) headroom for active HLS streams, preview thumbnails, and database operations.
- All media path, cache lookup, and subtitle delivery routines must resolve across `config.get_media_roots()`.

### Linux/Kali
- Python 3.10+; current development uses Python 3.14.x.
- `python3 -m venv`, `pip`, Git.
- FFmpeg and FFprobe on `PATH`.
- Production: Gunicorn/gthread; systemd is recommended.
- Remote access: cloudflared named tunnel.
- Keep origin on `127.0.0.1:8000` when Cloudflare is the public front end.

## 6. Player invariants

- Direct streams must remain isolated from transcoding status/polling logic.
- Seeking must not synchronously assign `currentTime` on every seek-bar drag event; commit on gesture completion.
- During scrubbing or browser seek, `timeupdate` must not snap the slider back to an old timestamp.
- Direct MP4/AAC seeking and MKV/HEVC HLS seeking must both remain functional.
- Preserve player container isolation and mobile viewport clamping.
- `templates/player.html` has a strict single-`<script>` invariant; external scripts must be dynamically injected from the existing script block.
- `/api/media-info` reports the **video stream's end** as `duration` for HLS playback and the container duration for direct play: HLS timelines come from our playlist, while a direct-play browser reads the file's own metadata and must not be desynced. Any HLS completeness denominator (chunks, progress, ENDLIST) must likewise use the video end — a WEBRip whose audio/subtitles outlive the picture otherwise shows an unplayable tail.
- Do not perform broad player rewrites for narrow playback bugs.

### HLS cache integrity (learned the hard way)

- **Segment indices are strided per chunk (`SEGMENTS_PER_CHUNK_STRIDE = 32`), and that is what
  keeps chunks from overwriting each other.** A 60 s chunk does **not** reliably emit the 15
  segments the plan expects: with the AMF encoders it emits 15, 16 or 17 depending on
  source/GPU/driver (the Vega 8 and RX 560X even disagree - pinning `-g` to a 4 s GOP makes the
  RX 560X emit a *single* 60 s segment, so no encoder-side setting fixes this). Under the old
  dense grid (`start_seg = round(start/4)`) an extra segment landed on the **next** chunk's first
  index, and whichever render finished last won - destroying ~1.25 s of the previous chunk's tail
  at **every** overflowing boundary. Live proof: of 10 caches, the nine whose chunks emitted
  exactly 15 segments have 0 packet gaps, while Spider-Man - the only cache with overflowing
  chunks (16 x70, 17 x15) - has exactly **85 gaps**, matching its 85 overflowing chunks.
  Consequences for anything that touches segments:
  - Never walk segment indices densely from 0 (`while segment_{idx}.ts exists`): it stops at the
    first inter-chunk gap and silently drops every later chunk (coverage read 50 % for a fully
    rendered 120 s source). Glob and sort instead, and bound a chunk's run by
    `start_seg + SEGMENTS_PER_CHUNK_STRIDE`.
  - Frame accounting must measure a chunk's **own run** of segments, not a fixed 15: measuring
    only the planned count made complete chunks look 1.25 s short.
  - A cache built on the old dense grid cannot be migrated in place (the indices *are* the
    ordering): `_prepare_cache_layout` clears an unmarked cache and re-renders it on the strided
    grid, marking the directory with `.seg_layout` = `stride32`.
  - `-force_key_frames` does not make the AMF encoders obey the plan, and `-g` changes the segment
    count rather than controlling it. Treat the segment count as unknown; the layout must
    tolerate it.

- **`#EXTINF` labels are honest - do not "correct" them.** A segment labelled 2.4 s really holds
  60 frames = 2.4 s of video at 25 fps. The trap is `ffprobe -show_entries format=duration` on a
  segment: the container duration includes the **audio pre-roll** (measured 4.33 s container vs
  2.4 s video for the same segment). Rewriting labels from that quantity overstates the video
  timeline and **hides real content loss** - it is how a 99.88 % "repair" once masked 277 s of
  missing frames. Never relabel a playlist from container durations.
- **Frame accounting is the only trustworthy content measure.** `chunk_content_deficits()`
  counts video packets per chunk and compares with `chunk window x source fps`; a real cache
  measured 100 % by duration while missing **277.2 s of frames across 101 chunks** (independent
  packet-PTS scan: 85 gaps / 279.4 s - the two agree within 2 s). A frame count of `-1` means
  *unknown* (unreadable file, no ffprobe, segment still being written) and must never be treated
  as empty, or every chunk looks deficient and the cache re-renders forever.
- **ENDLIST must never be written while any chunk is short of frames**, and a chunk with a frame
  deficit is not "rendered". `repair_understated_caches()` (cache-maintenance-worker) strips
  ENDLIST from caches that claim completion but are short, so the pipeline re-renders them. It
  never relabels: a genuinely short cache must be re-rendered, not rewritten.
- **Frame measurement must respect the cache's layout.** Per-chunk windows are exact *only* on the
  strided grid (`.seg_layout` = `stride32`). On a legacy dense cache chunk N's overflow segment
  sits on chunk N+1's first index, so a strided window reads a neighbour's segments for most
  chunks and a near-empty tail for the last ones - that is how three complete caches were
  reported as missing 38.5 s / 24.2 s / 13.7 s and had their ENDLIST stripped. `chunk_content_deficits()`
  therefore dispatches on `cache_uses_strided_layout()` and judges a dense cache on its
  whole-cache frame total (one aggregate entry, `chunk_id` -1).
- **Duplicate-job detection must not rely on `/proc`.** `find_ffmpeg_info_for_path()` originally
  scanned `/proc/[0-9]*/cmdline` only, so on Windows it returned `(None, None)` on every call and
  the guard in `ensure_hls_transcode()` never fired: the auto-transcoder started a second job on a
  cache another job was already rendering (two jobs, same segment indices). It now enumerates
  processes with `psutil` first and falls back to `/proc`. Caveat: a *user* process cannot read a
  *LocalSystem* process's command line (Windows access control), so the service can detect
  externally started encoders but not the reverse. `ensure_hls_transcode(filename, force=True)`
  skips the completeness gate and is only for a *measured* frame deficit.
- **Stripping ENDLIST is not a heal on its own - the re-render must be queued with it.**
  `_is_hls_truly_complete()` is label-based, and a frame-deficient cache's labels can still sum to
  100 %, so the auto-transcoder called such a cache complete and never touched it (the state
  Spider-Man sat in at 99.88 %). `repair_understated_caches()` calls `ensure_hls_transcode()` for
  every cache with a real deficit, including one already stripped by an earlier pass.
- **Resume from the label sum, never from container durations.** `_hls_resume_point()` resumes at
  the content the existing segments hold; resuming from inflated container durations skips
  content that still has to be produced.
- **Packet-PTS jumps at chunk boundaries are expected** (`#EXT-X-DISCONTINUITY` is declared
  there): `chunk_content_holes()` is diagnostic only and must never gate anything.
- **The chunk command itself is frame-complete** - verified with the exact job command shape,
  with/without `-c:a copy`, with/without `-output_ts_offset`, and with two chunks encoding
  concurrently on both GPUs (1500/1500 frames every time). A deficient cache is therefore legacy
  (older code or interrupted runs) and is healed by re-rendering, not by relabelling.
- **All segment measurement is memoised by (path, size, mtime)** and files younger than 3 s are
  skipped. The 1 Hz progress updater rebuilds the master playlist; an unmemoised probe there
  spawned ~1 ffprobe per chunk boundary per second for the whole run.
- **Playlist writes are serialised and atomic** (`_PLAYLIST_WRITE_LOCK`, `write_text_atomic`):
  a torn read is what `_hls_resume_point` then freezes into both `playlist.m3u8` and its `.bak`.
- Completeness decisions divide by `source_video_duration()` (the video-stream end), never the
  container duration: a WEB-DL container can run minutes past the last video frame and would mark
  a finished cache incomplete forever.
- Verification tools: `scripts/hls_content_gap_inventory.py` (label-independent packet audit of
  every cache), `scripts/hls_frame_audit.py` (per-chunk frame accounting), `scripts/hls_gop_matrix.py`
  (real dual-GPU pipeline over synthetic keyframe cadences), `scripts/final_verification_battery.py`,
  `scripts/snapshot_live_data.py`.

## 7. Testing protocol

Before committing:

```powershell
python -m py_compile app/config.py app/services/transcode_service.py app/services/chunk_transcode_service.py app/services/gpu_service.py
.\venv\Scripts\python.exe -m pytest tests/
```

Cache-directory safety when running the suite on the live host:
- `tests/conftest.py` owns test isolation: it redirects the cache, database, upload target/staging, archive and deleted directories onto a throwaway tree **through the environment before the app is imported** (so a `config` reload recomputes throwaway paths), re-asserts them before every test, and refuses any deletion inside the checkout's `cache/` tree. Never rely on import-time attribute rebinding alone: `tests/test_app.py`'s teardown reloads `app.config` and `tests/test_selenium_multi_seek_coyote.py` rebinds `app.CACHE_DIR = app.config.CACHE_DIR` — that is how a full-suite run once deleted the live transcode cache. `audit_orphaned_caches()` derives the "active" set from `video_paths()`, so any run whose cache is not isolated makes every real HLS directory look orphaned and the non-dry-run purge deletes production transcodes; likewise, `_resolve_upload_dirs()` returns `MEDIA_ROOT` under pytest, which once wrote 22-byte fixtures into the real library and fixture rows into the production database.
- Verify isolation the hard way after touching it: snapshot the library file list, the production `movies` rows and the `cache/hls` directory list (plus a hash of each) before and after a full run — all three must be unchanged.
- The orphan audit is fail-closed by design; do not reintroduce bare `except Exception: <empty active set>` handling around media enumeration.
- `purge_orphaned_caches()` refuses to run when the audit reports itself degraded, and skips any directory holding `hls.progress`/`playlist.m3u8`/`chunk_*.m3u8*` written within `RECENT_CACHE_GRACE_SECONDS` (live transcode). Startup no longer purges orphans unless `MEDIA_SERVER_PURGE_ON_STARTUP=1`.
- Never fall back to a bare `MEDIA_ROOT / user_input` join when `safe_path()` refuses a name, and never unlink without an `_is_within_media_roots()` check: the service runs as LocalSystem, so a traversal name in `/api/media/delete` deletes arbitrary host files (see `docs/PROJECT_STATUS.md`). Audit sibling deletion paths the same way.

Verify at minimum:
- Direct MP4/AAC playback.
- MKV/HEVC HLS playback.
- Seek to `0:00` and arbitrary positions.
- Seek-bar hover displays frame preview thumbnails.
- System Telemetry HUD reports active GPU engine load.
- Subtitles remain correctly positioned.
- No mobile horizontal/vertical layout regression.
