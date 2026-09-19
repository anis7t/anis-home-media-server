# Anis' Home Media Server

A modern, modular, self-hosted **personal home media server** built with Python and Flask for streaming a private movie library over a local network, with secure, CGNAT-compatible remote access through Cloudflare Named Tunnels.

The platform includes dedicated routes, services, utilities, background workers, SQLite persistence, dynamic multi-GPU chunked FFmpeg transcoding (AMD Radeon RX 560X + Vega 8), TMDb metadata ingestion, subtitle processing with automatic language detection, dual-drive storage tiering, resumable uploads, connected-device telemetry, live video seek preview thumbnails, an in-app User Manual, and persistent Windows Service hosting.

> **Current status:** Fully functional home media server. Core library and playback workflows are operational, hardware-accelerated transcoding utilizes dual AMD GPUs (Radeon RX 560X + Vega 8), live seek preview thumbnails are operational, and the system runs persistently as background Windows Services. See [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md) for the active engineering status record and [`docs/MANUAL.md`](docs/MANUAL.md) for the comprehensive user manual.

---

## Table of Contents

- [User Manual ("How to Use")](#user-manual--how-to-use)
- [Features](#features)
  - [Media Playback & Direct Play](#media-playback)
  - [Dynamic Multi-GPU Chunked Transcoding](#dynamic-multi-gpu-chunked-transcoding)
  - [Video Seek Hover Preview Thumbnails](#video-seek-hover-preview-thumbnails)
  - [Modern HTML5 Player & Controls](#player)
  - [Layered Seek Bar](#seek-bar)
  - [Subtitles & Dual-Axis Positioning](#subtitles)
  - [Metadata, Posters & Forensic Resolver](#metadata-and-library)
  - [Resumable Chunked Uploads](#uploads)
  - [Connected Device Telemetry](#connected-devices)
  - [Dual-Drive Storage Tiering & Cache Retention](#dual-drive-storage-tiering)
  - [Stats for Nerds & Multi-GPU Telemetry](#stats-for-nerds)
- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Media Pipeline](#media-pipeline)
- [Installation & Hosting](#installation)
  - [Windows 11 Production (NSSM Services)](#windows-hosting)
  - [Linux / Debian / Kali Hosting](#linux--kali--debian-family)
- [Configuration (.env)](#configuration)
- [Remote Access via Cloudflare Tunnel](#remote-access)
- [Active Roadmap & Next Steps](#active-roadmap--next-steps)
- [Testing & Invariants](#testing)
- [License and Attribution](#license-and-attribution)

---

## User Manual & "How to Use"

Complete user and operator documentation is available:
- **In-App Interactive Manual:** Accessible at [`/manual`](https://your-media-hostname.example.com/manual) directly from the footer on any page ("How to use").
- **Repository Documentation:** A complete, detailed Markdown user manual with touch gestures, player keybindings, and operational procedures is in [`docs/MANUAL.md`](docs/MANUAL.md).

---

# Features

## Media Playback

The server supports two primary playback paths:

### Direct Play
Compatible media is delivered directly using HTTP RFC 7233 byte-range streaming via zero-copy OS mechanisms (`send_file(conditional=True, etag=True)`). This avoids transcoding overhead and enables instant seeks for browser-compatible containers and codecs (e.g. MP4/M4V/WebM containing H.264/AAC).

### On-Demand HLS Transcoding
Media requiring compatibility conversion (such as MKV containers or HEVC/H.265 video) is converted into adaptive HLS playlists on-demand using FFmpeg. The transcode engine manages segment creation, cache reuse, interrupted transcode resumption, 1-second progress cadence, and automatic temporary file cleanup.

---

## Dynamic Multi-GPU Chunked Transcoding

To maximize encoding throughput on multi-GPU systems, the server incorporates a dynamic chunk-scheduling architecture (`chunk_transcode_service.py` & `gpu_service.py`):

- **Independent Worker Pipelines:** Rather than forcing multiple GPUs into a single encoder pipe, the server treats each GPU as an independent transcoding worker.
- **Dual-GPU Allocation:** On tested Windows systems with an AMD Radeon RX 560X discrete GPU and an AMD Radeon Vega 8 integrated GPU, jobs are distributed dynamically across FFmpeg D3D11 adapters `dx11:1` and `dx11:0`.
- **Keyframe-Aware Segmentation:** Source media is partitioned into sequential, keyframe-aligned chunks that are encoded concurrently by available GPUs and assembled into unified HLS playlists.
- **Real-Time Engine Telemetry:** Live hardware engine utilization for all engaged GPUs is tracked via Windows Performance Counters and PyNVML, displayed in the System Telemetry HUD and `/api/system/stats`.

---

## Video Seek Hover Preview Thumbnails

The player features YouTube-style interactive seek previews:

- **Live Frame Previews:** Hovering or scrubbing across the seek bar displays an accurate, high-fidelity frame thumbnail representing the exact target timestamp.
- **Dynamic Thumbnail Service:** `preview_service.py` extracts frame thumbnails on-demand using fast input-seeking (`-ss` before `-i`) and caches them under `cache/previews/` for instantaneous subsequent lookups.
- **Responsive Clamping:** Preview cards automatically clamp to viewport boundaries to ensure they never overflow screen edges on desktop or mobile devices.

---

## Player

The custom HTML5 player (`templates/player.html`) is built for both desktop precision and mobile ergonomics:

- **Responsive Viewport Clamping:** Absolute inset clamping prevents container height blowout on tiled or non-standard desktop windows.
- **Tap-to-Reveal Controls:** Single tap reveals playback controls without toggling play/pause; play/pause toggles only if controls are already visible.
- **Circular Geometries & Prominent Icons:** Uniform 36px circular control buttons with prominent 21px SVG icons.
- **Top Boundary Clearance:** Added 4px vertical breathing room to `.controls-row` to eliminate hover lift and focus outline clipping.
- **Native Dark Scheme Dropdowns:** Explicit `color-scheme: dark !important;` and dark styling for speed and subtitle dropdown options prevent white-on-white popups.
- **Hold-to-Speed Removal:** Eliminated hold-to-accelerate (2×) pointer gestures and removed hold shortcuts from the help modal in favor of clean standard dropdown control.
- **Compact Continue Watching Cards:** Carousel thumbnails sized to 140px on desktop (115px on mobile) with sub-scroll gesture isolation (`overscroll-behavior-x: contain; touch-action: pan-x;`).
- **Aspect Ratio & Rotation:** Cycle through native, 16:9, 4:3, zoom/crop, stretch, and 90° hardware rotation.

---

## Seek Bar

The YouTube-style layered seek bar (`static/js/seekbar-youtube.js` & `static/css/seekbar-youtube.css`) visualizes:
1. **Played Position:** Red progress fill.
2. **Buffered Position:** Semi-transparent buffered progress.
3. **Hover / Preview Position:** Visual ghost scrubber with live thumbnail preview and timestamp.
4. **Committed Playback Position:** Browser `currentTime` is committed strictly on pointer release (`pointerup`/`touchend`), preventing server range-request flooding during drag gestures.

---

## Subtitles

- **Supported Formats:** Local `.srt` and `.vtt` discovery and delivery.
- **SRT → WebVTT Conversion:** In-memory conversion supporting both `HH:MM:SS.mmm` and `MM:SS.mmm` timestamp formats.
- **Dual-Axis Positioning:** 
  - *Horizontal:* `center`, `left`, `right`.
  - *Vertical:* `lowered`, `bottom` (default), `raised`, `middle`, `top`.
- **Control Clearance:** Dynamic cue elevation ensures subtitles never collide with playback controls.

---

## Metadata and Library

- **TMDb Integration:** Automated movie details, ratings, cast, genres, backdrops, and posters.
- **Forensic Media Resolver:** Consensus-based forensic identification analyzes filenames, directory trees, and container metadata to resolve correct TMDb IDs for anonymous or device-uploaded files.
- **Library Scanner:** Background discovery and automatic ingestion of new library titles.

---

## Uploads

- **Resumable Chunked Transfers:** Upload multi-gigabyte files reliably over WAN or Cloudflare connections.
- **Smoothed Transfer Telemetry:** Exponential moving average transfer rate calculation with accurate remaining ETA.
- **Post-Upload Abort Concealment:** Immediately hides the Cancel/Abort button upon 100% upload completion to guard server-side processing.
- **Dynamic Ingestion Progress Card:** Displays animated cycling status labels (*Probing video stream...*, *Querying TMDb...*, *Caching posters...*, *Synchronizing subtitles...*) while backend workers index the media.

---

## Connected Devices

The `/devices` telemetry dashboard provides full visibility into connected clients:
- Hardware make, model, and OS decoding via Chromium High-Entropy Client Hints (`Sec-CH-UA-Model`, `Sec-CH-UA-Platform-Version`).
- Network classification (Local LAN vs Remote WAN, public IP, ISP/ASN organization).
- Visibility-aware keepalive heartbeats and `sendBeacon` departure telemetry.
- Friendly device renaming, active/offline filtering, and per-device watch history.

---

## Dual-Drive Storage Tiering

- **Tiered Multi-Volume Architecture:** Optimizes fast NVMe SSD (`C:`) for OS, SQLite (`media.db`), in-progress scratch, seek frame previews (`cache/previews`), and active HLS stream caches (`cache/hls`), while offloading cold raw media, upload staging (`D:\Flicks\.uploads`), and archives to mass storage (`D:\Flicks`, `D:\Flicks\.archive`).
- **Post-Transcode Retention Policies:** Configurable policies (`keep`, `archive`, `purge_cache`) persisted in the `settings` database table.
- **Safe Orphaned Cache Purge:** One-click automated cache reconciliation auditing and removing stale HLS directories without disrupting active transcodes.

---

## Stats for Nerds

Technical HUD (`n` / `N` key) reporting:
- Dropped vs total frames via `getVideoPlaybackQuality()`.
- Viewport resolution vs native stream resolution.
- Forward buffer length.
- Active stream type (Direct RFC 7233 vs HLS Transcode).
- Live GPU engine utilization.

---

# Architecture

```text
Browser / Client (Desktop, Tablet, Mobile)
                   │
                   ▼
       Cloudflare Named Tunnel (your-media-hostname.example.com)
                   │
                   ▼
       Waitress WSGI (127.0.0.1:8000) [NSSM Service]
                   │
                   ▼
         Flask Application Factory (app/__init__.py)
                   │
    ┌──────────────┼──────────────────────────┐
    ▼              ▼                          ▼
 Routes         Services                  Utilities
 ├─ pages.py    ├─ transcode_service.py   ├─ filesystem.py
 ├─ api.py      ├─ chunk_transcode_service.py ├─ formatting.py
 ├─ media.py    ├─ gpu_service.py         └─ subtitles.py
 ├─ upload.py   ├─ preview_service.py
 └─ subs.py     ├─ media_resolver.py
                ├─ device_service.py
                └─ system_service.py
                   │
    ┌──────────────┼──────────────────────────┐
    ▼              ▼                          ▼
 SQLite DB      Dual-GPU FFmpeg Workers    Local Media Root
 (media.db)     ├─ GPU 0: AMD RX 560X      (C:\Media)
                └─ GPU 1: AMD Vega 8
```

---

# Installation & Hosting

## Windows Hosting

### Prerequisites
- Windows 10/11 or Windows Server.
- Python 3.14+ (installed to `C:\MediaServer\venv`).
- FFmpeg 9.0+ with AMF/D3D11va support.
- NSSM (Non-Sucking Service Manager).
- Cloudflared CLI (`C:\Cloudflared\bin\cloudflared.exe`).

### Service Deployment via NSSM
The server runs persistently as a Windows Service named `MediaServer`:
```powershell
# Run the automated installer as Administrator
cd C:\MediaServer
.\scripts\install_service.bat
```
This configures:
- Service startup: `Automatic` (starts at boot without user login).
- Failure action: Automatic restart on crash.
- Log rotation: 10 MB threshold (`logs/waitress.log`).
- Environment: Automatic injection of FFmpeg binaries on `PATH`.

### Service Control
- Start / Restart: `scripts\restart_service.bat`
- Status Check: `powershell -ExecutionPolicy Bypass -File scripts\service_status.ps1`
- Uninstall: `scripts\uninstall_service.bat`

---

## Linux / Kali / Debian-family

```bash
git clone https://github.com/anis7t/media-server.git
cd media-server

python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Production execution via Gunicorn
gunicorn -c gunicorn.conf.py "app:create_app()"
```

---

# Configuration

Store environment variables in `C:\MediaServer\.env` (never commit this file):

```ini
TMDB_API_TOKEN=<your_tmdb_bearer_token>
MEDIA_SERVER_MEDIA_ROOT=C:\Media
MEDIA_SERVER_DATABASE=C:\MediaServer\media.db
MEDIA_SERVER_BASE_DIR=C:\MediaServer
MEDIA_SERVER_LOG_LEVEL=INFO
MEDIA_SERVER_TRANSCODE_PRESET=superfast
MEDIA_SERVER_TRANSCODE_CRF=23
MEDIA_SERVER_ENABLE_AMF=1
```

---

# Remote Access

Remote access is powered by a named Cloudflare Tunnel:
```text
Hostname: your-media-hostname.example.com
Origin:   http://127.0.0.1:8000
Service:  Cloudflared (Automatic Windows Service)
```

To resolve stale CNAME records dynamically without web dashboard intervention:
```powershell
cloudflared.exe tunnel route dns --overwrite-dns <TUNNEL_NAME_OR_UUID> your-media-hostname.example.com
```

---

# Active Roadmap & Next Steps

The next stage of development focuses on four specific engineering objectives:

### 1. In-Transcode Playback Synchronization & Timeline Offset
- **Issue:** When media is actively being transcoded into HLS, starting playback does not begin from `0:00`. It begins midway into the timeline despite the seek indicator showing `0:00`. Seeking behaves erratically and playback frequently halts after several seconds.
- **Root Cause:** Sliding-window live playlist semantics, non-zero presentation timestamps (PTS) without `#EXT-X-DISCONTINUITY`, and player buffer underruns when catching up to active transcoding.
- **Solution:** Implement VOD playlist synchronization (`#EXT-X-PLAYLIST-TYPE:EVENT` with explicit `#EXT-X-START:TIME-OFFSET=0`) or gate playback with an informative transcode progress screen until a safe initial buffer (or 100% completion) is achieved.

### 2. Periodic (4-Hour) TMDb Metadata Refresh & Manual Scan Trigger
- **Issue:** Movie ratings, vote counts, popularity scores, and poster artwork update continuously on TMDb, but are only ingested once during initial library addition.
- **Solution:** Implement a recurring 4-hour background worker in `worker_service.py` to refresh TMDb details for all library entries, and connect the UI "↻ Scan" button to trigger metadata re-synchronization.

### 3. Server-Wide Manual Subtitle Upload with Language Auto-Detection
- **Issue:** Users need the ability to upload `.srt` / `.vtt` subtitles after a movie is added, persisted server-wide across all sessions and devices.
- **Solution:** Add an upload modal on `/details/<filename>`. Detect subtitle language automatically from content text (via script analysis or language detection), and persist files using the standardized naming format:
  `<short_movie_name>_<detected_language>_<incremental_number>.<ext>`
  (e.g., `moana_en_1.srt`, `the_odyssey_fr_1.vtt`).

### 4. Post-Transcode Storage Strategy & Safe Orphaned Cache Purge
- **Issue:** Storing both large original files (5–20 GB MKV/HEVC) and full transcode caches causes disk bloat. Aborted transcodes also leave residual artifacts.
- **Solution:** Add configurable retention policies allowing users to delete/archive original sources post-transcode, and implement comprehensive orphaned cache auditing in `cache/hls/` against active database entries.

---

# Testing

Run the automated test suite before committing changes:

```powershell
# Syntax compile check
python -m py_compile app/config.py app/services/transcode_service.py app/services/chunk_transcode_service.py app/services/gpu_service.py

# Pytest suite (125 tests)
.\venv\Scripts\python.exe -m pytest tests/
```

---

# License and Attribution

Intended for personal media streaming and home-lab deployment. Metadata and imagery provided by **The Movie Database (TMDb)**.