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
- Do not perform broad player rewrites for narrow playback bugs.

## 7. Testing protocol

Before committing:

```powershell
python -m py_compile app/config.py app/services/transcode_service.py app/services/chunk_transcode_service.py app/services/gpu_service.py
.\venv\Scripts\python.exe -m pytest tests/
```

Verify at minimum:
- Direct MP4/AAC playback.
- MKV/HEVC HLS playback.
- Seek to `0:00` and arbitrary positions.
- Seek-bar hover displays frame preview thumbnails.
- System Telemetry HUD reports active GPU engine load.
- Subtitles remain correctly positioned.
- No mobile horizontal/vertical layout regression.
