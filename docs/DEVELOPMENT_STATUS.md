# Development Status / Session Handoff

Last updated: 2026-09-16
Repository: `anis7t/media-server`
Working branch: `fix/windows-purge-reliability`

## 1. Branch and Environment State

- **Current working branch:** `fix/windows-purge-reliability`
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

## 3. Active Next Steps & Engineering Tasks

### Issue 1: Periodic (4-Hour) TMDb Metadata Refresh & Manual Trigger
- **Problem:** Ratings, vote averages, popularity, and posters evolve on TMDb but remain static after initial ingestion.
- **Action Plan:** Add a 4-hour background scheduler in `worker_service.py` to refresh TMDb details for all records in `media.db`. Wire up the UI "↻ Scan" button to trigger metadata re-synchronization.

### Issue 2: Server-Wide Manual Subtitle Upload with Language Auto-Detection
- **Problem:** Users need to manually upload external `.srt` / `.vtt` subtitles persisted server-wide.
- **Action Plan:** Add upload modal on `/details/<filename>`, detect language from text content, and save using the standardized format:
  `<short_movie_name>_<detected_language>_<incremental_number>.<ext>`
  (e.g., `moana_en_1.srt`, `the_odyssey_fr_1.vtt`).

### Issue 3: Post-Transcode Storage Retention & Safe Orphaned Cache Purge
- **Problem:** Storing multi-gigabyte source files alongside full transcode caches causes disk bloat. Aborted transcodes leave residual artifacts.
- **Action Plan:** Add configurable retention policies allowing users to delete/archive original sources post-transcode, and implement comprehensive orphaned cache auditing in `cache/hls/` against active database entries.

---

## 4. Verification & Testing

Before committing changes, execute:

```powershell
# Automated Test Suite (131 tests)
.\venv\Scripts\python.exe -m pytest tests/
```

