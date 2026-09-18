# Anis' Home Media Server — Personal Media Server

A modern, modular, self-hosted **personal media server** built with Python and Flask for streaming a private movie library over a local network, with optional remote access through Cloudflare Tunnel.

The project has evolved from an early monolithic Flask application into a structured media platform with dedicated routes, services, utilities, background workers, SQLite persistence, FFmpeg-based transcoding, TMDb metadata ingestion, subtitle processing, resumable uploads, playback telemetry, connected-device telemetry, and cross-platform deployment support.

> **Current status:** Functional development-stage personal media server. Core library and playback workflows are operational, but Windows hardware-transcoding validation, Windows automatic startup, authentication/access control, Cloudflare media-delivery review, and several player UI issues remain open. See [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md) for the detailed status record.

---

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Media Pipeline](#media-pipeline)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running](#running)
- [Remote Access](#remote-access)
- [Windows AMD AMF](#windows-amd-amf)
- [Library and Metadata](#library-and-metadata)
- [Uploads](#uploads)
- [Subtitles](#subtitles)
- [Player and Seeking](#player-and-seeking)
- [Device Telemetry](#device-telemetry)
- [Stats for Nerds](#stats-for-nerds)
- [Testing](#testing)
- [Performance](#performance)
- [Security](#security)
- [Known Issues](#known-issues)
- [Development Rules](#development-rules)
- [Documentation](#documentation)
- [Roadmap](#roadmap)
- [License and Attribution](#license-and-attribution)

---

# Features

## Media Playback

The server supports two primary playback paths:

### Direct Play

Compatible media can be delivered directly using HTTP byte-range streaming. This avoids unnecessary transcoding and allows browsers to seek efficiently within the original file.

Direct playback is intended for browser-compatible media such as MP4/M4V/WebM containing supported codecs such as H.264/AAC.

### On-Demand HLS

Media that cannot be played directly by the browser can be converted into HLS using FFmpeg. This is especially useful for MKV and HEVC/H.265 sources.

The transcoding service handles:

- FFmpeg process creation
- HLS segmentation
- Cache reuse
- Interrupted/resumed transcoding where supported
- Progress/state reporting
- Cleanup of temporary output
- Seek-aware playback

A core architectural rule is that direct streams must remain direct streams; player polling or seeking must not accidentally trigger transcoding.

## Player

The custom HTML5 player includes:

- Responsive desktop/mobile layouts
- Tap/click-to-reveal controls
- Resume playback and persisted playback state
- Playback-speed selection
- Picture-in-picture where supported
- Fullscreen-related controls
- SVG player icons
- Subtitle controls
- Screen rotation/aspect controls
- Playback telemetry
- Stats for Nerds HUD
- Transcoding/network status
- Touch-friendly controls
- Keyboard shortcuts
- Reduced-motion support
- Back/forward-cache navigation resilience
- Mobile overflow protection

The normal playback-speed selector is separate from the historical **hold-to-speed-up** gesture. Removal of that gesture is currently parked and should not be mixed into unrelated player changes.

## Seek Bar

The player uses a YouTube-style layered seek bar with separate visual concepts for:

1. Played position.
2. Buffered position.
3. Hover/preview position.
4. Committed playback position.

Scrubbing is designed so that pointer movement primarily changes visual state; `video.currentTime` is committed when the gesture finishes. This prevents excessive range requests and prevents `timeupdate` from fighting the user during a seek.

### Known seek-preview issue

The `.seek-preview` and `.seek-preview-time` elements exist in the player DOM, but the **frame preview and hover timestamp are currently not visibly rendering as intended**. This is a known unresolved UI issue from the YouTube-style seek-bar implementation.

This is **different from** the older issue where the elapsed-time display above the seek bar could visually appear paused even though the movie continued playing.

Future fixes should diagnose the DOM/computed CSS/positioning/z-index/opacity behavior first and should avoid a broad player rewrite.

## Subtitles

Local subtitle support includes:

- `.srt`
- `.vtt`
- In-memory SRT → WebVTT conversion
- Horizontal positioning: left, center, right
- Vertical positioning: lowered, bottom, raised, middle, top

Positioning was tuned to keep subtitles clear of player controls, especially on mobile screens.

Automatic OpenSubtitles behavior remains intentionally parked because the previous automatic behavior was not sufficiently reliable.

## Metadata and Library

The ingestion system uses TMDb for metadata and artwork and includes a media resolver designed to avoid blindly trusting filenames.

Capabilities include:

- Library scanning
- Media probing through FFprobe
- TMDb identification
- Multi-source/consensus resolution
- Forensic matching for ambiguous or anonymous files
- Poster caching
- Backdrop caching
- Genre/rating/title metadata
- Post-upload ingestion
- Subtitle discovery

This is particularly important for remote/mobile uploads whose filenames may be generic or device-generated.

## Uploads

Uploads use a resumable/chunked workflow suitable for unreliable or remote connections.

The UI provides:

- Chunked transfer
- Resume behavior
- Smoothed transfer-rate reporting
- Dynamic ETA
- Backend processing status
- Media probing status
- TMDb indexing status
- Poster/artwork processing status
- Subtitle processing status

An upload is therefore treated as the beginning of an ingestion workflow rather than merely the arrival of a file.

## Connected Devices

The `/devices` dashboard provides operational telemetry about clients using the server.

It can resolve or display:

- Phone/tablet/desktop classification
- Manufacturer/OEM
- Model
- Operating system and version
- Chromium High-Entropy Client Hints where supported
- Local/LAN/remote network path
- Client public IP information where available
- ISP/ASN organization where available
- LAN MAC information where available from ARP data
- Active/offline status
- Last-seen time
- Watch history

The system uses visibility-aware heartbeats and page lifecycle telemetry rather than maintaining an unnecessarily aggressive connection.

Device management includes friendly renaming, Active Now/Offline filtering, removal, and per-device history inspection.

## Stats for Nerds

The in-player technical HUD is intended for diagnosing playback problems. Depending on browser support, it exposes:

- Dropped frames
- Total frames
- Native resolution
- Viewport resolution
- Forward buffer
- Playback/transcode state

The HUD can be opened from the player or with the `n` / `N` shortcut where supported.

---

# Architecture

The application is now organized around an application factory, route blueprints/modules, services, utilities, background workers, SQLite, FFmpeg/FFprobe, and external TMDb metadata.

```text
                         Browser
                            │
                  HTTP / Range / HLS
                            │
                            ▼
                  ┌──────────────────┐
                  │   Flask App      │
                  │ Application      │
                  │ Factory          │
                  └────────┬─────────┘
                           │
          ┌────────────────┼─────────────────┐
          │                │                 │
          ▼                ▼                 ▼
       Routes           Services          Utilities
          │                │                 │
          │       ┌────────┼────────┐        │
          │       │        │        │        │
          │       ▼        ▼        ▼        │
          │     Media   Transcode  TMDb      │
          │     Resolver Subtitles Scanner   │
          │     Devices Workers   System     │
          │                                   │
          └──────────────┬────────────────────┘
                         │
              ┌──────────┼──────────┐
              ▼          ▼          ▼
           SQLite     FFmpeg/FFprobe  Media
                         │
                         ▼
                    HLS / Cache
```

## Repository Structure

```text
media-server/
├── app.py
├── requirements.txt
├── gunicorn.conf.py
├── scanner.py
├── posters.py
├── server.sh
├── AGENTS.md
├── GEMINI.md
├── README.md
│
├── app/
│   ├── __init__.py
│   ├── config.py
│   ├── db.py
│   ├── routes/
│   │   ├── api.py
│   │   ├── media.py
│   │   ├── pages.py
│   │   ├── subtitles.py
│   │   └── upload.py
│   ├── services/
│   │   ├── device_service.py
│   │   ├── media_resolver.py
│   │   ├── media_service.py
│   │   ├── scanner_service.py
│   │   ├── subtitles_service.py
│   │   ├── system_service.py
│   │   ├── tmdb_service.py
│   │   ├── transcode_service.py
│   │   └── worker_service.py
│   └── utils/
│       ├── filesystem.py
│       ├── formatting.py
│       └── subtitles.py
│
└── docs/
    ├── DEVELOPMENT_STATUS.md
    ├── LOAD_TESTING.md
    ├── PROJECT_STATUS.md
    ├── REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md
    └── WINDOWS_SETUP.md
```

### Responsibility overview

- `app.py` — lightweight executable entry point.
- `app/__init__.py` — Flask application factory and compatibility exports.
- `app/config.py` — environment-driven configuration.
- `app/db.py` — SQLite connections, schema and migrations.
- `routes/pages.py` — HTML pages/navigation.
- `routes/api.py` — JSON/API operations, playback state, metadata and devices.
- `routes/media.py` — media delivery and range requests.
- `routes/subtitles.py` — subtitle/WebVTT delivery.
- `routes/upload.py` — upload/chunk workflow.
- `media_service.py` — media operations/probing.
- `media_resolver.py` — media identity resolution.
- `scanner_service.py` — library discovery/ingestion.
- `tmdb_service.py` — TMDb integration.
- `transcode_service.py` — FFmpeg/HLS generation, caching and cleanup.
- `subtitles_service.py` — subtitle processing.
- `device_service.py` — device telemetry and lifecycle tracking.
- `worker_service.py` — background worker coordination.
- `system_service.py` — system-level telemetry/status.
- `utils/*` — reusable filesystem, formatting and subtitle helpers.

---

# Media Pipeline

```text
Movie selected
     │
     ▼
Probe / inspect media
     │
     ▼
Browser-compatible?
   /          \
 YES          NO
  │             │
  ▼             ▼
Direct Range   Start or reuse HLS
Streaming         │
  │               ▼
  │             FFmpeg
  │               │
  │               ▼
  │          HLS segments
  │               │
  └───────┬───────┘
          ▼
       Browser
          │
          ▼
       Playback
```

The server should prefer direct play whenever the source is suitable. Software transcoding consumes CPU, while hardware encoding can reduce CPU pressure when properly configured and validated.

---

# Installation

## Linux / Kali / Debian-family

```bash
git clone https://github.com/anis7t/media-server.git
cd media-server

python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Verify prerequisites:

```bash
python3 --version
ffmpeg -version
ffprobe -version
```

## Windows

The current tested layout is:

```text
C:\MediaServer       repository
C:\Flicks            media root
C:\MediaServer\media.db
C:\MediaServer\venv
C:\Cloudflared\cloudflared.exe
```

Create the environment:

```powershell
cd C:\MediaServer
py -m venv venv
.\venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Verify:

```powershell
python --version
ffmpeg -version
ffprobe -version
```

The currently tested Windows workstation uses Python 3.14.3.

---

# Configuration

Configuration is environment-driven. A typical `.env` contains:

```ini
TMDB_API_TOKEN=your_tmdb_bearer_token_here
MEDIA_SERVER_MEDIA_ROOT=/path/to/media
MEDIA_SERVER_DATABASE=/path/to/media.db
MEDIA_SERVER_BASE_DIR=/path/to/media-server
MEDIA_SERVER_LOG_LEVEL=INFO
MEDIA_SERVER_TRANSCODE_PRESET=superfast
MEDIA_SERVER_TRANSCODE_CRF=23
MEDIA_SERVER_ENABLE_VAAPI=0
MEDIA_SERVER_VAAPI_DEVICE=/dev/dri/renderD128
MEDIA_SERVER_ENABLE_AMF=0
```

Windows example:

```ini
MEDIA_SERVER_MEDIA_ROOT=C:\Flicks
MEDIA_SERVER_DATABASE=C:\MediaServer\media.db
MEDIA_SERVER_BASE_DIR=C:\MediaServer
MEDIA_SERVER_ENABLE_AMF=1
```

### Configuration variables

| Variable | Purpose |
|---|---|
| `TMDB_API_TOKEN` | TMDb bearer credential |
| `MEDIA_SERVER_MEDIA_ROOT` | Root media directory |
| `MEDIA_SERVER_DATABASE` | SQLite database path |
| `MEDIA_SERVER_BASE_DIR` | Project/cache base directory |
| `MEDIA_SERVER_LOG_LEVEL` | Application logging level |
| `MEDIA_SERVER_TRANSCODE_PRESET` | FFmpeg software-encoding preset |
| `MEDIA_SERVER_TRANSCODE_CRF` | FFmpeg software H.264 quality setting |
| `MEDIA_SERVER_ENABLE_VAAPI` | Linux VAAPI enable switch |
| `MEDIA_SERVER_VAAPI_DEVICE` | Linux VAAPI render device |
| `MEDIA_SERVER_ENABLE_AMF` | Windows AMD AMF enable switch |

**Never commit `.env`, API tokens, Cloudflare credentials, passwords, private keys, or other secrets.**

---

# Running

## Development

```bash
python app.py
```

The application uses port `8000` by default:

```text
http://127.0.0.1:8000
```

LAN clients can use the server's LAN address if the firewall allows it.

## Linux Production

Use Gunicorn rather than Flask's development server. The current documented baseline is:

- 1 worker
- gthread worker class
- 8 threads
- 120-second timeout in the load-testing configuration

Example lifecycle commands:

```bash
systemctl --user start media-server.service
systemctl --user restart media-server.service
systemctl --user status media-server.service
```

For unattended operation, systemd user lingering is recommended.

## Windows Production

Use **Waitress**, not Gunicorn.

The intended topology is:

```text
Waitress → 127.0.0.1:8000 → Flask
                          ▲
                          │
                    cloudflared
```

Manual Waitress/cloudflared operation has been verified. Final automatic startup and restart-on-failure behavior remains work in progress.

---

# Remote Access

Cloudflare Tunnel is used to provide remote access even when the home connection is behind CGNAT.

For temporary development/testing:

```bash
cloudflared tunnel --url http://127.0.0.1:8000
```

This produces a temporary `trycloudflare.com` hostname.

The preferred permanent architecture uses a named tunnel:

```text
Remote Browser
      │
      ▼
Cloudflare Edge
      │
      ▼
Named cloudflared tunnel
      │
      ▼
127.0.0.1:8000
      │
      ▼
Flask application
```

The current deployment uses a custom hostname and a named tunnel. Tunnel credentials are private machine configuration and must never enter Git.

### Important security distinction

Cloudflare Tunnel provides connectivity/routing. It is **not application authentication**.

Before wider remote sharing, the application needs an explicit authentication/access-control strategy.

See [`docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`](docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md) for deployment details.

---

# Windows AMD AMF

The Windows deployment is being extended with AMD AMF hardware H.264 encoding.

The tested machine has:

- Radeon RX 560X discrete GPU
- AMD Vega 8 integrated GPU

A crucial finding is that **Windows Task Manager GPU numbering must not be assumed to equal FFmpeg D3D11 adapter numbering**.

On the tested host, FFmpeg D3D11 adapter `1` selects the discrete RX 560X.

The intended hardware initialization is:

```text
-init_hw_device d3d11va=dx11:1
-init_hw_device amf=amf@dx11
-filter_hw_device amf
```

The encoder should use `h264_amf`.

Verify available AMF encoders with:

```powershell
ffmpeg -hide_banner -encoders | Select-String "amf"
```

and hardware accelerators with:

```powershell
ffmpeg -hide_banner -hwaccels
```

Seeing `h264_amf` in the encoder list is **not sufficient** to prove that the discrete GPU is being used.

Before merging the AMF branch, validate all of the following with a real HEVC movie:

1. D3D11 adapter selection is explicit.
2. AMF initializes successfully.
3. `h264_amf` is actually used.
4. The RX 560X shows the expected workload.
5. Vega 8 is not unintentionally selected.
6. Browser playback remains stable.

---

# Library and Metadata

The ingestion workflow combines file discovery, probing, media identification and TMDb metadata.

```text
File discovered/uploaded
        │
        ▼
     FFprobe
        │
        ▼
Evidence / filename / media data
        │
        ▼
 Media resolver
        │
        ▼
      TMDb
        │
        ├── Metadata
        ├── Poster
        └── Backdrop
        │
        ▼
 Subtitle discovery
        │
        ▼
   Library entry
```

Root-level helpers include:

```bash
python scanner.py
python posters.py
```

The resolver is designed to reduce false matches and handle anonymous/mobile-generated filenames more safely than simple filename-only matching.

---

# Uploads

Uploads are resumable/chunked so remote transfers can recover from interruptions without necessarily restarting the entire file.

The upload pipeline tracks transfer speed and ETA and then continues into backend ingestion. This allows the UI to distinguish:

```text
Uploading
   ↓
Assembling
   ↓
Probing
   ↓
Identifying
   ↓
TMDb indexing
   ↓
Artwork caching
   ↓
Subtitle processing
   ↓
Ready
```

---

# Subtitles

Local subtitle files are discovered next to media and served to the browser through WebVTT-compatible output.

Supported formats:

```text
.srt
.vtt
```

Horizontal alignment:

```text
Left | Center | Right
```

Vertical elevation:

```text
Top | Middle | Raised | Bottom | Lowered
```

Future player/layout changes must preserve both axes and the deliberate clearance above playback controls.

---

# Player and Seeking

The player is built around browser HTML5 media APIs and custom controls.

Important invariants:

- Direct media remains direct media.
- Direct seeking uses HTTP range delivery.
- HLS media remains on the HLS/transcoding path.
- Dragging the seek bar must not create unnecessary request storms.
- Playback must continue correctly after seeking.
- `timeupdate` must not overwrite the slider during active scrubbing.
- Keyboard shortcuts must continue to work when the range slider has focus.
- Mobile layouts must not overflow.
- Subtitle positioning must remain intact.
- Player controls must remain touch-friendly.

The current seek-preview visibility problem should be investigated with browser DevTools before modifying the player. In particular inspect `.seek-preview` and `.seek-preview-time` for computed `display`, `visibility`, `opacity`, dimensions, position, transform and z-index.

The player also maintains a single-script-block/template invariant; broad template restructuring is discouraged.

---

# Device Telemetry

The `/devices` page is an operational dashboard for connected clients.

A simplified lifecycle is:

```text
Browser
  │
  ├── Client hints
  ├── Heartbeat
  ├── pagehide beacon
  └── Playback/device data
          │
          ▼
   Device service
          │
          ▼
        SQLite
          │
          ▼
     /devices UI
```

The dashboard can identify device class, OEM/model/OS, network path, last-seen status and watch history. Friendly names, Active Now/Offline filters and device removal are supported.

Because telemetry can contain IP-related information, device identifiers and viewing history, this subsystem should be treated as private operational data.

---

# Stats for Nerds

The player HUD exists specifically to make playback troubleshooting easier.

Typical information includes:

| Metric | Meaning |
|---|---|
| Dropped frames | Frames the browser failed to render |
| Total frames | Total reported playback frames where supported |
| Native resolution | Source/video resolution |
| Viewport resolution | Displayed video dimensions |
| Forward buffer | Approximate buffered playback duration |
| Transcode state | Whether backend processing is active |

Browser support varies, so telemetry should be treated as diagnostic information rather than an absolute measurement.

---

# Testing

Run Python compilation checks:

```bash
python -m py_compile app/config.py app/services/transcode_service.py
```

Run automated tests:

```bash
python -m pytest
```

If the checkout contains a dedicated `tests/` directory:

```bash
python -m pytest tests/
```

### Core regression areas

Test coverage and project regression checks include:

- Application factory
- SQLite migrations/schema
- Routing
- Device tracking
- Client hints
- Heartbeats
- Subtitle parsing
- Cue positioning
- WebVTT conversion
- HLS caching/transcoding
- Media resolution
- Seek behavior

### Manual player regression checklist

After player/transcoding changes verify:

1. MP4/H.264/AAC direct playback.
2. MKV/HEVC HLS playback.
3. Seek to `0:00`.
4. Seek to an arbitrary position.
5. Playback continues after seek.
6. Seek UI does not freeze while playback continues.
7. Dragging does not flood the server with requests.
8. Subtitles remain correctly positioned.
9. Mobile layout remains within the viewport.
10. Transcode status is truthful.
11. Picture-in-picture/fullscreen still work where supported.
12. Browser back/forward navigation remains stable.

### Windows AMF checklist

For AMF changes also verify adapter selection, actual `h264_amf` use, discrete-GPU utilization, and successful browser playback.

---

# Performance

The documented Linux baseline was tested on an AMD Ryzen 5 3550H system with approximately 13 GB RAM, using one Gunicorn gthread worker with eight threads and direct H.264/AAC playback.

### Local origin

The test reached:

- **100 concurrent streams**
- **100% request success**
- Approximately **104.6 Mbps aggregate throughput**
- Approximately **4.719 s average TTFB** at 100 streams
- Approximately **8.95 s p95 TTFB** at 100 streams
- Approximately **46% maximum CPU**
- Approximately **38% RAM utilization**

### Through Cloudflare

The documented production-path test showed:

- **10 streams:** passed the documented TTFB threshold.
- **15 streams:** all completed, but average TTFB reached approximately **11.575 s**, exceeding the test threshold.

The current analysis indicates that remote performance is primarily constrained by upstream Internet bandwidth and Cloudflare/network latency rather than local CPU or RAM.

These figures are measurements of one environment, workload and network. They are not guarantees for different hardware, codecs, bitrates, clients, ISPs, Cloudflare paths, or transcoding workloads.

See [`docs/LOAD_TESTING.md`](docs/LOAD_TESTING.md) for detailed measurements.

---

# Security

This server is intended for private/home-lab use and should not be treated as an authenticated public service by default.

Never commit:

- `.env`
- TMDb tokens
- Cloudflare credentials
- Passwords
- Private keys
- Session secrets
- API keys

Prefer binding the origin to localhost when Cloudflare is the external access layer.

Before broad remote sharing, implement or place an authentication/access-control layer in front of the application.

Also review Cloudflare's current policies and technical suitability for personal large-file/video delivery before increasing remote streaming scale. A tunnel that technically works is not automatically the correct architecture for arbitrary video traffic.

---

# Known Issues

The following are intentionally documented rather than hidden so future contributors and coding agents understand the current state.

### 1. Windows AMD adapter selection

AMF must be explicitly pinned to the D3D11 adapter corresponding to the discrete RX 560X on the tested Windows host.

### 2. Playback transcoding indicator blinks

The playback transcoding pill/status indicator can repeatedly blink. Before editing code, determine whether polling changes visibility, JavaScript replaces the element, or CSS animation is being restarted.

### 3. Windows automatic startup

Waitress and cloudflared currently work manually. Final boot-time startup with restart-on-failure and no interactive terminal dependency remains incomplete.

### 4. Seek frame preview / hover timestamp not visible

The DOM elements exist, but the visual frame preview and hover timestamp do not currently render correctly. This is a known UI issue from the recent YouTube-style seek bar.

### 5. Hold-to-speed-up

Removal of the hold-click/hold-press speed acceleration gesture is parked. The ordinary speed selector should remain.

### 6. Automatic OpenSubtitles

The incorrect automatic OpenSubtitles behavior is parked for later investigation.

### 7. Authentication

Application authentication/access control is not yet considered complete.

### 8. Cloudflare media-delivery policy

The remote video-delivery architecture needs a policy/limits review before scaling it broadly.

### 9. Concurrency tuning

One worker/eight threads is a tested baseline, not a final universal production configuration. More workers/threads should be benchmarked rather than assumed to help.

---

# Development Rules

This repository is developed with coding-agent assistance, so changes should be conservative and evidence-driven.

## Prefer small, isolated commits

Do not perform broad refactors to solve narrow player or transcoding bugs.

## Preserve known-good baselines

The `testing` branch is intentionally treated as a known-good baseline during the current development cycle. Do not force-push or rewrite protected baselines.

## Diagnose browser issues first

For UI bugs:

1. Reproduce.
2. Inspect DOM.
3. Inspect computed CSS.
4. Inspect Network → Fetch/XHR.
5. Inspect Console.
6. Determine whether the fault is frontend state, DOM, CSS, timing or backend behavior.
7. Make the smallest fix.
8. Run regressions.

## Preserve playback invariants

Never accidentally convert direct-play media into a transcode workflow. Never reintroduce seek request storms. Never allow `timeupdate` to fight an active seek gesture.

## Preserve subtitles and mobile layout

Player changes must retain both-axis subtitle positioning and must be checked at narrow viewport sizes.

## Avoid process leaks

FFmpeg and background workers must remain bounded and cleaned up correctly. Do not introduce unbounded process creation.

## Protect destructive actions

Confirmation dialogs for purge/removal operations must remain resistant to accidental outside-touch dismissal.

## Protect secrets

Secrets stay on the machine. They do not belong in source, documentation, screenshots or commits.

---

# Documentation

The repository contains dedicated operational documentation:

- [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md) — current architecture, completed work, verified performance, known bugs, requirements, testing rules and immediate work queue.
- [`docs/DEVELOPMENT_STATUS.md`](docs/DEVELOPMENT_STATUS.md) — development/deployment history and environment state.
- [`docs/LOAD_TESTING.md`](docs/LOAD_TESTING.md) — detailed concurrency and throughput tests.
- [`docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`](docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md) — Cloudflare remote-access architecture.
- [`docs/WINDOWS_SETUP.md`](docs/WINDOWS_SETUP.md) — Windows-specific setup.
- [`AGENTS.md`](AGENTS.md) — repository engineering rules and invariants for coding agents.
- [`GEMINI.md`](GEMINI.md) — detailed agent instructions and regression constraints.

`PROJECT_STATUS.md` is the best place to look for the current development state; this README is the broader project guide.

---

# Roadmap

## Priority 1 — Correctness and deployment

1. Explicitly bind Windows AMF to RX 560X through the intended D3D11 adapter.
2. Validate real HEVC → H.264 AMF playback.
3. Diagnose/fix the blinking playback-transcoding indicator.
4. Run complete automated and player regression tests.
5. Finish Windows automatic startup for Waitress + cloudflared.

## Priority 2 — Remote-access hardening

6. Implement/choose authentication and access control.
7. Review Cloudflare media-delivery and large-file considerations.
8. Re-test remote concurrency after deployment changes.

## Priority 3 — Player polish

9. Fix seek-bar frame-preview/hover-timestamp visibility.
10. Revisit hold-to-speed-up removal only when explicitly resumed.
11. Continue player improvements without breaking playback invariants.

## Priority 4 — Deferred functionality

12. Investigate automatic OpenSubtitles behavior.
13. Improve metadata-resolution edge cases.
14. Evaluate additional hardware-transcoding options where useful.

---

# License and Attribution

This project is intended for private/personal media streaming and home-lab use.

Media metadata and imagery are provided through **The Movie Database (TMDb)**. Individual deployments are responsible for complying with applicable licenses, terms of service, copyright requirements and local law concerning their media and third-party services.

---

# Project at a Glance

```text
┌──────────────────────────────────────────────────────────┐
│                     MY MOVIES SERVER                     │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  LIBRARY                    PLAYBACK                      │
│  ├─ Scanner                 ├─ Direct Play               │
│  ├─ Resolver                ├─ HLS Transcoding            │
│  ├─ TMDb                    ├─ Seeking                    │
│  ├─ Posters                 ├─ Subtitles                  │
│  └─ Metadata                ├─ Resume                     │
│                             └─ Telemetry                  │
│                                                          │
│  MANAGEMENT                 REMOTE ACCESS                │
│  ├─ Resumable Uploads       ├─ Cloudflare Tunnel         │
│  ├─ Devices                 ├─ CGNAT compatibility        │
│  ├─ Watch History           └─ Named tunnel               │
│  └─ Purge                                                │
│                                                          │
│  OPERATIONS                 HARDWARE                     │
│  ├─ SQLite                  ├─ FFmpeg                     │
│  ├─ Background Workers      ├─ Software H.264             │
│  ├─ Status                  └─ AMD AMF development         │
│  └─ Caching                                               │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

The core server is already capable of serving a real personal library over LAN and through a tunneled remote path. The next stage is not a wholesale rewrite: it is disciplined validation, deployment hardening, authentication, hardware-transcoding verification, player bug fixes, and measured performance tuning.
