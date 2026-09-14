# Project Status, Completed Work, Bugs & Hosting Requirements

Last reviewed: 2026-09-15
Repository: `anis7t/media-server`
Default branch reviewed: `main`

## 1. Executive summary

This is a Flask-based personal media server designed for LAN playback and remote access. The codebase has been substantially modularized from the earlier monolithic application into an `app/` package containing routes, services, utilities, configuration, and database code. The server supports direct media streaming, on-demand HLS transcoding, TMDb metadata, local subtitles, uploads, library management, device telemetry, playback telemetry, and Cloudflare Tunnel remote access.

The project is functional, but it is still a development-stage personal server rather than a finished hardened production product. The highest-priority unresolved items are: Windows GPU adapter selection for AMD AMF, the blinking playback transcoding indicator, reliable Windows automatic startup, authentication/access control, and validation of the public media-delivery architecture through Cloudflare.

## 2. Current repository architecture

### Application entry points

- `app.py` — lightweight executable entry point.
- `app/__init__.py` — application factory and compatibility exports.
- `app/config.py` — environment-driven paths, limits, and runtime settings.
- `app/db.py` — SQLite connection/schema/migration support.

### HTTP routes

- `app/routes/pages.py` — HTML pages and page navigation.
- `app/routes/api.py` — JSON/API endpoints including devices, metadata and playback state.
- `app/routes/media.py` — media streaming/range delivery.
- `app/routes/subtitles.py` — local subtitle/WebVTT delivery.
- `app/routes/upload.py` — resumable/chunked upload workflow.

### Services

- `media_service.py` — media probing, paths and media operations.
- `media_resolver.py` — automatic/forensic media identification and TMDb matching.
- `scanner_service.py` — library discovery and ingestion.
- `tmdb_service.py` — TMDb API integration.
- `transcode_service.py` — FFmpeg/HLS transcoding, caching, resume and cleanup.
- `subtitles_service.py` — subtitle discovery/conversion/processing.
- `device_service.py` — client/device identification, telemetry, heartbeats and device history.
- `worker_service.py` — background worker coordination.
- `system_service.py` — system-level status/telemetry functionality.

### Utilities

- `filesystem.py` — safe filesystem/path helpers.
- `formatting.py` — display formatting helpers.
- `subtitles.py` — subtitle parsing/conversion helpers.

## 3. Completed major work

### Media playback

- Direct byte-range streaming for compatible MP4/M4V/WebM media.
- On-demand HLS transcoding for formats requiring compatibility conversion, including MKV/HEVC workflows.
- HLS cache reuse and resume handling for interrupted transcoding.
- Transcode progress/status reporting.
- Player controls, responsive layouts, gestures, picture-in-picture and fullscreen-related controls.
- Playback state/resume persistence and throttled progress synchronization.
- YouTube-style layered seek bar with played/buffered/hover visualization and pointer-friendly scrubbing.
- Range/seek handling was hardened to avoid flooding the server with range requests during drag operations.
- Direct-stream seeking regressions, including Oculus playback, were previously fixed.

### Subtitles

- Local `.srt` and `.vtt` discovery.
- Local subtitle HTTP delivery.
- In-memory SRT-to-WebVTT conversion.
- Horizontal subtitle alignment.
- Vertical subtitle positioning including lowered/bottom/raised/middle/top.
- Subtitle placement was adjusted to avoid overlapping playback controls.
- Incorrect automatic OpenSubtitles behavior remains intentionally parked.

### Metadata and ingestion

- TMDb metadata lookup and local artwork caching.
- Automatic media identification using multiple evidence sources.
- Forensic matching improvements intended to reduce false TMDb matches.
- Anonymous/mobile upload filenames can be handled without blindly guessing metadata.
- Scanner and upload paths integrate automatic media resolution.

### Uploads and management

- Resumable chunked uploads for remote/Cloudflare use.
- Upload speed smoothing and ETA display.
- Post-upload processing status for probing, metadata, posters and subtitles.
- Library management page with destructive purge handling.
- Destructive confirmation modals were hardened against accidental backdrop dismissal.

### Device telemetry

- `/devices` dashboard.
- Client type detection and Chromium high-entropy client hints.
- Device make/model/OS decoding for common Android/OEM identifiers.
- Local/LAN/remote network-path classification.
- Public IP/ISP telemetry where available.
- LAN MAC lookup where available from the server's ARP information.
- Active/offline state with heartbeat and last-seen timestamps.
- Device renaming, removal, filters and per-device watch history.

### Player telemetry

- Stats-for-Nerds HUD.
- Dropped/total frame telemetry through `getVideoPlaybackQuality()` where supported.
- Native versus viewport resolution reporting.
- Forward-buffer calculation.
- Transcode-state visibility.

### UI/UX

- Responsive mobile layouts.
- Mobile overflow and long-title/metadata clamping fixes.
- Modern player controls and SVG icons.
- Page transitions and top progress indicator.
- Reduced-motion handling.
- Navigation/back-forward-cache resilience.
- Site-wide footer/privacy UI on primary pages.

### Deployment and remote access

- Production WSGI path for Linux using Gunicorn/gthread.
- Cross-platform production path for Windows using Waitress.
- `ProxyFix` support for reverse-proxy/tunnel headers.
- Named Cloudflare Tunnel architecture with custom hostname `media.anisparvez.in`.
- CGNAT-compatible remote access without router port forwarding.
- Linux systemd service/lingering guidance.
- Windows setup documentation and AMD AMF development work are present.

## 4. Verified performance baseline

The documented Linux load test used Ryzen 5 3550H, 13 GB RAM, a single Gunicorn gthread worker with 8 threads, and direct H.264/AAC playback.

- Local origin testing reached 100 concurrent streams with 100% request success.
- Production testing through the Cloudflare Tunnel reached 10 concurrent streams within the documented TTFB threshold.
- At 15 production streams, delivery still completed but average TTFB exceeded the 10-second acceptance threshold.
- The documented production bottleneck is primarily upstream Internet bandwidth plus tunnel/network latency, not CPU or RAM.
- The 8-thread Gunicorn pool also creates queuing at high local concurrency.

These are capacity measurements for the tested environment, not guarantees for other networks, media bitrates, hardware, or clients.

## 5. Known bugs / unresolved issues

### P0/P1 — must resolve before calling the current build production-ready

#### A. Playback transcoding indicator blinks repeatedly

Observed on the playback page: `#shellTranscodePill` / `#stpDot` / `#stpText` repeatedly blinks while playback is running.

Current status: **unresolved**.

Do not guess at the cause. Inspect DevTools first and determine whether:

1. polling alternates the element between shown/hidden states;
2. JavaScript repeatedly replaces the DOM node; or
3. a CSS animation is being restarted on every status update.

Useful diagnostic areas: Network → Fetch/XHR and the element's computed/display state over time.

#### B. Windows AMD AMF is not yet explicitly pinned to the discrete GPU

The Windows machine has two AMD GPUs. A standalone FFmpeg D3D11 test established that FFmpeg adapter index `1` selects the discrete Radeon RX 560X on the tested machine.

The AMF application branch currently needs explicit D3D11 adapter binding so the server cannot accidentally use the integrated Vega 8. Intended initialization:

```text
-init_hw_device d3d11va=dx11:1
-init_hw_device amf=amf@dx11
-filter_hw_device amf
```

This must be verified with a real HEVC movie and Windows Task Manager before merge.

#### C. Windows automatic startup is incomplete

Waitress and cloudflared work manually, but reliable boot-time startup has not yet been finalized.

Required end state:

```text
Windows boot/login
  -> Media Server (Waitress) on 127.0.0.1:8000
  -> named cloudflared tunnel
  -> media.anisparvez.in
```

The startup mechanism must keep secrets outside Git and provide restart-on-failure behavior.

### P2 — known functional/feature debt

#### D. Hold-to-speed-up player gesture

The request to remove hold-click/hold-press playback-speed acceleration while retaining the normal playback-speed dropdown is parked. A previous formatted player edit caused a Jinja/player regression and was reverted.

Do not modify the player template for this item unless it is explicitly resumed.

#### E. Automatic OpenSubtitles behavior

Local subtitles work, but the incorrect automatic OpenSubtitles behavior is intentionally parked for later investigation.

#### F. Authentication/access control

The Cloudflare hostname provides stable remote routing but is not application authentication. Authentication/access control remains necessary before wider public sharing.

#### G. Public video-delivery architecture needs policy review

The current Cloudflare Tunnel path is technically functional, but the project's public media-delivery model should be reviewed against Cloudflare's current service-specific video/large-file policies and the intended usage. Do not assume a personal movie library should be delivered through the public CDN/proxy path at arbitrary scale.

#### H. Production concurrency tuning is not finalized

The tested Linux deployment uses one Gunicorn worker and eight gthread threads. Increasing threads or workers may reduce application-side queuing, but this must be benchmarked rather than assumed to improve end-to-end remote performance. The ISP upload path remains the dominant remote bottleneck.

## 6. Platform requirements

### Linux / Kali / Debian-family hosting

#### Required software

- Python 3.10+; current development/testing uses Python 3.14.x.
- `pip` and `venv`.
- FFmpeg and FFprobe available on `PATH`.
- Git.
- Optional but recommended for production: systemd.
- Optional for remote access: `cloudflared`.

#### Python dependencies

Install with:

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

`requirements.txt` includes Flask, requests, python-dotenv, Waitress, and Gunicorn on non-Windows platforms.

#### Recommended production topology

```text
Client
  -> Cloudflare Tunnel (optional)
  -> 127.0.0.1:8000
  -> Gunicorn gthread
  -> Flask app
  -> FFmpeg / SQLite / media storage
```

Use a systemd service for the application and a managed cloudflared service for remote access. If using a user-level systemd service, enable lingering for the service account so it survives logout and starts at boot.

#### Linux hardware/storage considerations

- CPU matters for software H.264 transcoding.
- A supported GPU/FFmpeg hardware encoder can reduce CPU load.
- SSD storage is preferable for the database, transcode cache and high-concurrency media workloads.
- Ensure sufficient free space for the configured transcode cache (currently capped at 10 GB by application configuration).
- For large libraries, monitor cache growth, media storage and SQLite backups.

### Windows hosting

#### Required software

- Windows 10/11 or a supported Windows Server release.
- Python 3.10+; current tested workstation uses Python 3.14.3.
- PowerShell.
- FFmpeg and FFprobe available on `PATH` or configured through the application environment.
- Git.
- Optional for remote access: `cloudflared.exe`.

#### Current tested layout

```text
C:\MediaServer       repository
C:\Flicks            media root
C:\MediaServer\media.db
C:\MediaServer\venv
C:\Cloudflared\cloudflared.exe
```

#### Python environment

```powershell
cd C:\MediaServer
py -m venv venv
.\venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

#### Production server

Use Waitress rather than Gunicorn on Windows:

```powershell
python run_production.py
```

Prefer binding the origin to `127.0.0.1:8000` when cloudflared is the remote-access front end. Do not expose the origin directly to the Internet unless there is a deliberate firewall/authentication design.

#### AMD AMF

For AMD hardware encoding, FFmpeg must expose the AMF encoders and the required D3D11 support. Verify with:

```powershell
ffmpeg -hide_banner -encoders | Select-String "amf"
ffmpeg -hide_banner -hwaccels
```

Do not assume Windows Task Manager GPU numbering equals FFmpeg D3D11 adapter numbering. Adapter selection must be tested on the actual host.

#### Windows startup requirement

The final deployment should run both Waitress and the named cloudflared tunnel automatically, with restart-on-failure and no interactive terminal dependency. A service-based approach is preferred. Keep tunnel credentials and API tokens in protected local configuration, never in the repository.

## 7. Configuration contract

Recommended environment variables:

```ini
TMDB_API_TOKEN=<secret>
MEDIA_SERVER_MEDIA_ROOT=<absolute media directory>
MEDIA_SERVER_DATABASE=<absolute or project-relative SQLite path>
MEDIA_SERVER_BASE_DIR=<project/cache base directory>
MEDIA_SERVER_LOG_LEVEL=INFO
MEDIA_SERVER_TRANSCODE_PRESET=superfast
MEDIA_SERVER_TRANSCODE_CRF=23
MEDIA_SERVER_ENABLE_VAAPI=0
MEDIA_SERVER_VAAPI_DEVICE=/dev/dri/renderD128
MEDIA_SERVER_ENABLE_AMF=0
```

`MEDIA_SERVER_ENABLE_AMF=1` is currently relevant to the Windows AMD work. Do not copy real secrets into documentation or agent instructions.

## 8. Testing requirements before merging changes

At minimum:

```bash
python -m py_compile app/config.py app/services/transcode_service.py
python -m pytest tests/
```

For player/transcoding changes, additionally verify:

- Direct MP4/AAC playback.
- MKV/HEVC HLS playback.
- Seeking to `0:00` and arbitrary positions.
- Playback continues after a seek.
- Seek-bar HUD does not freeze while video continues.
- Subtitles remain correctly positioned.
- Player does not overflow mobile viewports.
- Transcoding status accurately reflects the backend state.

For Windows AMF changes:

- Verify the FFmpeg command contains the intended D3D11 adapter selection.
- Start a real HEVC transcode.
- Confirm `h264_amf` is actually used.
- Confirm the discrete RX 560X receives the workload.
- Confirm integrated Vega 8 is not unintentionally selected.

## 9. Agent safety rules

- Treat `testing` / known-good baselines as protected until explicitly approved.
- Prefer small, isolated commits.
- Never force-push or rewrite the protected baseline.
- Never commit `.env`, TMDb tokens, Cloudflare credentials/tokens, passwords, private keys or other secrets.
- Do not add local machine-specific startup scripts unless explicitly requested.
- Do not perform broad player rewrites to fix a narrowly scoped playback issue.
- Diagnose browser issues with DevTools before changing player JavaScript/CSS.
- Preserve direct-stream versus transcoded-stream separation.
- Preserve range-seeking invariants and avoid synchronous `currentTime` updates during seek-bar dragging.
- Preserve subtitle horizontal/vertical positioning behavior.
- Preserve destructive-modal touch immunity.
- Preserve mobile overflow protections.

## 10. Immediate work queue

1. Fix/verify explicit AMD D3D11 adapter `1` → RX 560X binding on the AMF branch.
2. Re-test a real HEVC movie and confirm discrete-GPU utilization.
3. Diagnose and fix the blinking playback transcoding pill.
4. Run the complete Python test suite and player regression checks.
5. Finish Windows automatic startup for Waitress + cloudflared.
6. Decide on authentication/access control before wider remote sharing.
7. Re-evaluate Cloudflare media-delivery suitability and limits for the intended library/use pattern.
8. Resume the hold-to-speed-up removal only when explicitly requested.
9. Investigate automatic OpenSubtitles behavior after the higher-priority deployment/player items are stable.
