# Development Status / Session Handoff

Last updated: 2026-09-17
Repository: `anis7t/media-server`
Working branch: `feat/storage-retention-cache-purge`

## 1. Branch and Environment State

- **Current working branch:** `feat/storage-retention-cache-purge`
- **Environment:** Windows 11 Home / Workstation
- **Tested Hardware:** AMD Ryzen 5 3550H, 16 GB RAM
- **Discrete GPU:** AMD Radeon RX 560X (4GB VRAM) — Task Manager GPU 0 / FFmpeg `dx11:1`
- **Integrated GPU:** AMD Radeon Vega 8 Graphics — Task Manager GPU 1 / FFmpeg `dx11:0`
- **Python:** 3.14.3 (`C:\MediaServer\venv`)
- **FFmpeg:** 9.0.1 essentials build with AMF & D3D11va
- **cloudflared:** 2026.9.1 (`C:\Cloudflared\bin\cloudflared.exe`)

```text
Project:       C:\MediaServer
Media root:    C:\Flicks
Archive root:  D:\Flicks\.archive (215.8 GB free pool on D:)
Database:      C:\MediaServer\media.db
Venv:          C:\MediaServer\venv
```

---

## 2. Completed Architecture & Features

### Dynamic Multi-GPU Transcoding Engine
- Implemented `app/services/gpu_service.py` and `app/services/chunk_transcode_service.py`.
- Both GPUs (Radeon RX 560X and Vega 8) transcode independent, keyframe-aligned segments of the same source file concurrently.
- Hardware engine utilization for all engaged GPUs is dynamically polled via Windows Performance Counters and PyNVML, displayed in the System Telemetry HUD and `/api/system/stats`.
- Transcode polling cadence optimized to 1 second for live progress, speed, and ETA calculation.

### Live Seek Hover Preview Thumbnails
- Implemented `app/services/preview_service.py` with fast keyframe extraction (`-ss` before `-i`) and server-side disk caching under `cache/previews/`.
- Integrated seamlessly into the YouTube-style seekbar (`seekbar-youtube.js` & `seekbar-youtube.css`) with responsive viewport boundary clamping.

### Persistent Windows Services
- Registered `MediaServer` (Waitress WSGI on `127.0.0.1:8000`) as an automatic Windows Service using NSSM.
- Configured automatic boot startup without requiring active user login, crash auto-recovery, 10 MB log rotation (`logs/waitress.log`), and injected FFmpeg environment paths.
- Registered `Cloudflared` as an automatic Windows Service with dynamic DNS route overwrite capability (`media.anisparvez.in`).

### Upload Lifecycle UX Hardening
- Implemented immediate Cancel/Abort button concealment upon 100% byte completion in `static/js/nav.js`.
- Restored animated dynamic processing card showing cycling background indexing stages (*Probing video stream...*, *Querying TMDb...*, *Caching posters...*, *Synchronizing subtitles...*).

### Player Controls & Visual Polish
- Removed hold-to-speed-up (2×) pointer gestures and removed hold shortcuts from the help modal (`#shortcutsModal`).
- Applied `color-scheme: dark !important;` and dark styling for speed and subtitle dropdown options.
- Added 4px vertical padding to `.controls-row` to eliminate hover lift and focus outline clipping.
- Enforced uniform 36px circular button geometries and enlarged SVG icons from 18px to 21px.
- Compacted "Continue watching" rail cards to 140px on desktop (115px on mobile).

### In-Progress Transcode HLS Synchronization & Purge Safety
- Enforced `#EXT-X-START:TIME-OFFSET=0` and `#EXT-X-PLAYLIST-TYPE:EVENT` during active chunked transcoding until full completion (`#EXT-X-ENDLIST`).
- Configured monotonic `-output_ts_offset` to prevent PTS resets across chunk boundaries.
- Dynamically parsed real `#EXTINF` segment durations from chunk playlists to eliminate timeline drift.
- Added thread-safe worker PID tracking (`DualGPUTranscodeJob.get_active_pids()`) and process self-termination guards for safe cache purging.

### Subdirectory Subtitles & Language Auto-Detection
- Resolved Werkzeug `<path:filename>/<name>` route collision for media stored in subfolders.
- Implemented `detect_subtitle_language()` heuristic analyzing Unicode character scripts and stop-word frequency to auto-detect language (`en`, `es`, `fr`, `de`, `it`, `pt`, `ru`, `zh`, `ja`, `ko`, `ar`, `bn`).
- Prioritized local subtitles as default (`default: True`) over external OpenSubtitles downloads when language matches.

---

### Periodic (4-Hour) TMDb Metadata Refresh & Manual Scan Trigger
- Background scheduler (`metadata-refresh-worker`) in `worker_service.py` refreshing TMDb details (ratings, vote averages, runtime, tagline, cast, certification, artwork) every 4 hours.
- SQLite `last_metadata_refresh` schema migration in `media.db`.
- Synchronized manual UI "↻ Scan" trigger re-synchronizing metadata alongside newly discovered files.

### Server-Wide Manual Subtitle Upload with Language Auto-Detection
- Built subtitle upload interfaces on `/movie/<filename>` and directly inside the in-player Subtitle Settings modal (`#subSettingsModal`).
- Auto-detects subtitle language from content text (Unicode character script analysis & NLP stop-word heuristic), saving files server-wide in canonical format: `<short_movie_name>_<detected_language>_<incremental_number>.<ext>`.
- In-player modal dynamically updates `<track>` elements and selects newly uploaded subtitles with zero playback disruption.

### Post-Transcode Storage Retention & Safe Orphaned Cache Purge
- **Configurable Retention Policies:** User-configurable retention policies (`keep`, `archive`, `purge_cache`) persisted in the `settings` database table. Default `'keep'` operates non-destructively while `'archive'` moves original source MKVs to `D:\Flicks\.archive` (utilizing 215+ GB headroom on drive `D:`) while preserving smooth HLS streaming.
- **Automated Orphaned Cache Auditing:** `audit_orphaned_caches()` reconciles `cache/hls/` and `cache/previews/` against active video files and in-flight transcode jobs.
- **Safe Orphaned Cache Purge:** `purge_orphaned_caches()` with bounded Windows file-lock retries, triggered automatically on server launch (`cleanup_cache_on_startup`) and by background daemon worker every 2 hours (`cache-maintenance-worker`). Reclaimed 57 orphaned cache directories.
- **REST API Suite:** Endpoints `/api/storage/audit`, `/api/storage/purge-orphans`, `/api/storage/settings`, and `/api/storage/archive/<filename>`.
- **Management UI:** Storage Retention & Cache Governance card on `/manage` with live storage pool telemetry, interactive policy selector, clean orphaned caches confirmation modal (`#cleanOrphansModal`), and per-item source archiving action.

---

## 3. Active Next Steps & Engineering Tasks

### Production Concurrency Tuning & Remote Streaming Benchmarks
- Benchmark Waitress worker and thread pools against remote stream latency, Cloudflare tunnel limits, and concurrent client playback.
- Optimize ISP upload bandwidth saturation and test concurrent multi-device streaming performance.

---

## 4. Verification & Testing

Before committing changes, execute:

```powershell
# Compile validation
python -m py_compile app/config.py app/services/transcode_service.py app/services/chunk_transcode_service.py app/services/gpu_service.py

# Automated Test Suite (158 tests)
.\venv\Scripts\python.exe -m pytest tests/
```


