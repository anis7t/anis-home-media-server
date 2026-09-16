# Project Status, Completed Work, Bugs & Hosting Requirements

Last reviewed: 2026-09-17
Repository: `anis7t/media-server`
Working branch: `feat/storage-retention-cache-purge`

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
- TMDb metadata resolution with forensic filename identification.
- Connected device telemetry dashboard (`/devices`) with Chromium High-Entropy Client Hints, network classification, and heartbeats.
- Technical Stats for Nerds HUD (`n` / `N` key) reporting dropped frames, viewport resolution, forward buffer, and stream state.

---

### Post-transcode storage retention & safe orphaned cache purge
- **Configurable Retention Policies:** Implemented user-configurable post-transcode retention policies (`keep`, `archive`, `purge_cache`) persisted in the `settings` database table. Default `'keep'` guarantees non-destructive operation while `'archive'` moves original source MKVs to `D:\Flicks\.archive` (preserving primary SSD headroom while leveraging high-capacity secondary storage) to free active library storage while preserving smooth HLS streaming.
- **Automated Orphaned Cache Auditing:** Implemented `audit_orphaned_caches()` in `transcode_service.py` to reconcile all directories under `cache/hls/` and `cache/previews/` against active video paths and in-flight transcodes.
- **Safe Orphaned Cache Purge Engine:** Built `purge_orphaned_caches(dry_run=False)` with bounded Windows file-lock retry semantics (`_remove_path_with_retries`), automatically executed during server startup (`cleanup_cache_on_startup`) and by background daemon worker every 2 hours (`cache-maintenance-worker`). Reclaimed 57 orphaned cache directories on the host pool.
- **REST API Endpoints:** Added `/api/storage/audit`, `/api/storage/purge-orphans`, `/api/storage/settings`, and `/api/storage/archive/<filename>` with input validation and dry-run preview support.
- **Management UI & Governance Dashboard:** Enhanced `/manage` with Storage Retention & Cache Governance card showing host storage pool utilization, interactive retention policy selector with instant persistence toast, real-time orphaned cache counter badge, clean orphaned caches confirmation modal (`#cleanOrphansModal`), and per-item source archiving action.

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

# Full automated test suite (158 tests)
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
