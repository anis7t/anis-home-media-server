# Anis' Home Media Server

A modern, high-performance, self-hosted **personal home media server** built with **Rust (Axum)**, **React 19**, and **PostgreSQL 18** for streaming a private movie library over a local network, with secure remote access over a static public IP behind **Caddy** and Let's Encrypt TLS.

The platform includes 100% native Rust routes, services, background workers, PostgreSQL persistence, dynamic multi-GPU chunked FFmpeg transcoding (AMD Radeon RX 560X + Vega 8), TMDb metadata ingestion, native subtitle extraction with automatic language detection, OTT-style QR device sign-in for camera-less devices, dual-drive storage tiering, resumable uploads, connected-device telemetry, live video seek preview thumbnails, an in-app User Manual, and persistent Windows Service hosting.

> **Current status:** Fully modernized and functional home media server. 100% native Rust Axum backend on port 8000 (`MediaServerRust`), React 19 SPA frontend (`web/dist/`), PostgreSQL 18.4 database (`MediaServerPG`), hardware-accelerated transcoding utilizing dual AMD GPUs (Radeon RX 560X + Vega 8), live seek preview thumbnails, and persistent background Windows Services. See [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md) for the active engineering status record and [`docs/MANUAL.md`](docs/MANUAL.md) for the comprehensive user manual.

## Android app

The universal Android client is available from the site's **Get the app** link
or directly at [`/download`](https://media.anisparvez.in/download). The current
production release is documented in
[`docs/ANDROID_APP_DISTRIBUTION.md`](docs/ANDROID_APP_DISTRIBUTION.md), including
the verified publishing and deployment procedure.

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
  - [QR Device Sign-In (TV & Browser)](#qr-device-sign-in)
  - [Dual-Drive Storage Tiering & Cache Retention](#dual-drive-storage-tiering)
  - [Stats for Nerds & Multi-GPU Telemetry](#stats-for-nerds)
- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Media Pipeline](#media-pipeline)
- [Installation & Hosting](#installation)
  - [Windows 11 Production (NSSM Services)](#windows-hosting)
  - [Linux / Debian / Kali Hosting](#linux--kali--debian-family)
- [Configuration (.env)](#configuration)
- [Remote Access via Static IP & Caddy](#remote-access)
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

To maximize encoding throughput on multi-GPU systems, the server incorporates a dynamic chunk-scheduling architecture implemented natively in Rust (`rust/src/transcode/` & `rust/src/services/gpu.rs`):

- **Independent Worker Pipelines:** Rather than forcing multiple GPUs into a single encoder pipe, the server treats each GPU as an independent transcoding worker.
- **Dual-GPU Allocation:** On tested Windows systems with an AMD Radeon RX 560X discrete GPU and an AMD Radeon Vega 8 integrated GPU, jobs are distributed dynamically across FFmpeg D3D11 adapters `dx11:1` and `dx11:0`.
- **Keyframe-Aware Segmentation:** Source media is partitioned into sequential, keyframe-aligned chunks that are encoded concurrently by available GPUs and assembled into unified fMP4 HLS playlists.
- **Real-Time Engine Telemetry:** Live hardware engine utilization for all engaged GPUs is tracked via Windows Performance Counters and PyNVML, displayed in the System Telemetry HUD and `/api/system/stats`.

---

## Video Seek Hover Preview Thumbnails

The player features YouTube-style interactive seek previews:

- **Live Frame Previews:** Hovering or scrubbing across the seek bar displays an accurate, high-fidelity frame thumbnail representing the exact target timestamp.
- **Dynamic Thumbnail Service:** Fast input-seeking (`-ss` before `-i`) extracts frame thumbnails on-demand and caches them under `cache/previews/` for instantaneous subsequent lookups.
- **Responsive Clamping:** Preview cards automatically clamp to viewport boundaries to ensure they never overflow screen edges on desktop or mobile devices.

---

## Player

The custom React 19 cinema player (`web/src/pages/PlayerPage.tsx`) is built for both desktop precision and mobile ergonomics:

- **Responsive Viewport Clamping:** Absolute inset clamping prevents container height blowout on tiled or non-standard desktop windows.
- **Tap-to-Reveal Controls:** Single tap reveals playback controls without toggling play/pause; play/pause toggles only if controls are already visible.
- **Circular Geometries & Prominent Icons:** Uniform circular control buttons with prominent SVG icons.
- **Native Dark Scheme Dropdowns:** Explicit dark styling for speed and subtitle dropdown options prevent white-on-white popups.
- **Compact Continue Watching Cards:** Carousel thumbnails sized to 140px on desktop (115px on mobile) with sub-scroll gesture isolation (`overscroll-behavior-x: contain; touch-action: pan-x;`).
- **Aspect Ratio & Rotation:** Cycle through native, 16:9, 4:3, zoom/crop, stretch, and 90° hardware rotation.

---

## Seek Bar

The YouTube-style layered seek bar (`web/src/components/LayeredSeekBar.tsx`) visualizes:
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

- **Resumable Chunked Transfers:** Upload multi-gigabyte files reliably over WAN or LAN connections.
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

## QR Device Sign-In

OTT-style activation for camera-less devices — smart TVs, desktop browsers, consoles — the same
idea as the Netflix / YouTube TV *"enter this code on your phone"* screen.

- **On the TV or browser:** `/account` shows a QR image, a 5-character code, and a 2-minute
  countdown ring. No keyboard required.
- **On the phone:** scan the QR (or type the code at `media.anisparvez.in/remotelogin`), sign in,
  and name the device — *"Living Room TV"*. The TV signs itself in.
- **Native implementation:** six Rust Axum endpoints under `/api/auth/qr/*` backed by a
  PostgreSQL `device_pair_sessions` table, with a Server-Sent-Events push stream and a JSON
  polling fallback.
- **Security:** every token — the pair code, the session id, the session cookie, the OAuth
  state/nonce, the PKCE verifier — is drawn from the operating system's CSPRNG and fails closed if
  the random source is unavailable. The pair code carries 25 bits of entropy.

Full detail: [`docs/QR_SIGNIN_WALKTHROUGH.md`](docs/QR_SIGNIN_WALKTHROUGH.md).

---

## Dual-Drive Storage Tiering

- **Tiered Multi-Volume Architecture:** Optimizes the fast SSD `E:` (`E:\MediaServer`) for the application runtime, PostgreSQL database cluster (`E:\pgdata`), in-progress transcode scratch, seek frame previews (`E:\MediaServer\cache\previews`), and active fMP4 HLS stream caches (`E:\MediaServer\cache\hls`), while offloading cold raw media, upload staging (`D:\Flicks\.uploads`), deleted-source staging (`D:\Flicks\.deleted`), and archives to high-capacity storage `D:` (`D:\Flicks`, `D:\Flicks\.archive`). `C:` is not used by this project.
- **Post-Transcode Retention Policies:** Configurable policies (`keep`, `archive`, `purge_cache`) persisted in PostgreSQL `settings` table.
- **Safe Orphaned Cache Purge:** One-click automated cache reconciliation auditing and removing stale HLS directories without disrupting active transcodes.

---

## Stats for Nerds

Technical HUD (`n` / `N` key) reporting:
- Dropped vs total frames via `getVideoPlaybackQuality()`.
- Viewport resolution vs native stream resolution.
- Forward buffer length.
- Active stream type (Direct RFC 7233 vs Adaptive fMP4 Stream).
- Live GPU engine utilization.

---

# Architecture

```text
Browser / Client (Desktop, Tablet, Mobile) / Android App / Fire TV Stick 4K
                   │
                   ▼
       Caddy Reverse Proxy (80/443, Let's Encrypt TLS) [MediaServerCaddy]
                   │  (Airtel static IP 122.163.124.18 -> media.anisparvez.in)
                   ▼
       Rust Axum Server (127.0.0.1:8000) [MediaServerRust NSSM Service]
                   │
    ┌──────────────┼──────────────────────────────┐
    ▼              ▼                              ▼
 React 19 SPA   API Router                  Transcode Engine
 (web/dist/)    ├─ api.rs (catalog/system)  ├─ planner.rs
                ├─ auth.rs (pin/session)    ├─ queue.rs
                ├─ qr_auth.rs (QR sign-in)  ├─ engine.rs (dual-GPU)
                ├─ media.rs (RFC 7233)      └─ sweeper.rs
                ├─ hls.rs (fMP4/quality)
                ├─ subtitles.rs (native)
                ├─ download.rs (APK stream)
                └─ manage.rs (storage)
                   │
    ┌──────────────┴──────────────────────────────┐
    ▼                                             ▼
PostgreSQL 18.4 (MediaServerPG, port 5432)   Local Media Roots
(E:\pgdata\ - movies, progress, settings)    ├─ D:\Flicks (raw media)
                                             ├─ D:\Flicks\.archive
                                             └─ D:\Flicks\.uploads
```

---

# Installation & Hosting

## Windows Hosting

### Prerequisites
- Windows 10/11 or Windows Server.
- Rust 1.85+ (MSRV 2021 edition) & Cargo.
- Node.js 20+ & npm (for building the React SPA in `web/`).
- PostgreSQL 18.4 (installed as Windows Service `MediaServerPG`).
- FFmpeg 9.0+ with AMF/D3D11va support.
- NSSM (Non-Sucking Service Manager).
- Static Public IP (`122.163.124.18`, Airtel Xstream Fiber) with Router Port Forwarding (`443`, `80` → `192.168.1.16`). ⚠️ Port `8000` is currently forwarded too and should be removed — it exposes the origin over plain HTTP, bypassing Caddy and TLS.

### Persistent Services via NSSM
The server runs persistently as automatic Windows Services:
1. **MediaServerRust**: Native Rust Axum binary (`rust\target\release\media-server-api.exe`) listening on `0.0.0.0:8000`.
2. **MediaServerCaddy**: Reverse proxy and TLS terminator on `80`/`443`, fronting `127.0.0.1:8000` with a Let's Encrypt certificate.
3. **MediaServerPG**: PostgreSQL 18.4 server listening on `127.0.0.1:5432`.
4. **Public Ingress**: Direct WAN routing via Static IP (`122.163.124.18`) and A-record `media.anisparvez.in`.

### Service Control
- Restart Server: `scripts\restart_rust_service.bat`
- Check Status: `powershell -ExecutionPolicy Bypass -File scripts\service_status.ps1`
- Backup Database: `scripts\backup_postgres.bat`
- Restore Database: `python scripts\restore_postgres.py <backup_file>`

---

## Linux / Debian / Kali Hosting

```bash
git clone https://github.com/anis7t/media-server.git
cd media-server

# Build React frontend
cd web && npm ci && npm run build && cd ..

# Build Rust binary
cd rust && cargo build --release && cd ..

# Run native binary
./rust/target/release/media-server-api
```

---

# Configuration

Store environment variables in `E:\MediaServer\.env` (never commit this file):

```ini
DATABASE_URL=postgres://postgres:<password>@127.0.0.1:5432/media_server
RUST_PORT=8000
RUST_HOST=0.0.0.0
TMDB_API_TOKEN=<your_tmdb_bearer_token>
MEDIA_SERVER_MEDIA_ROOT=D:\Flicks
MEDIA_SERVER_BASE_DIR=E:\MediaServer
MEDIA_SERVER_CACHE_DIR=E:\MediaServer\cache
MEDIA_SERVER_LOG_LEVEL=INFO
MEDIA_SERVER_ENABLE_AMF=1
```

---

# Remote Access

Remote access is powered by a **static public IP** fronted by **Caddy**:

```text
Hostname: media.anisparvez.in  (A-record -> 122.163.124.18, Airtel Xstream Fiber)
Ingress:  Caddy on 80/443, Let's Encrypt TLS 1.3 (DNS-01 challenge, auto-renewed)
Origin:   http://127.0.0.1:8000
Service:  MediaServerCaddy (Automatic Windows Service)
```

Caddy provides unbuffered HTTP/2 and HTTP/3 streaming and proxies Server-Sent Events
(`text/event-stream`) without delay — which the QR sign-in wait stream depends on.

> The **Cloudflare named tunnel is decommissioned**. The `cloudflared` service has been removed and
> the DNS record is DNS-only. Cloudflare is still used for DNS hosting and the DNS-01 challenge
> only; it is no longer in the traffic path.

---

# Modernization Status & Roadmap

The architecture is **100% modernized**:
- **Phase 0–9 + Slice 7E Delivered**: Full native Rust Axum backend, React 19 SPA, PostgreSQL 18.4 persistence, adaptive fMP4 streaming with dynamic quality ladder, client capability probing, and complete decommissioning of legacy Flask/Waitress code.
- **Client Stability**: Preserved 100% contract compatibility for the universal Android / Fire TV client (`scripts/probe_android_api.py`).
- **Public Ingress**: Migrated from the Cloudflare named tunnel to a direct static IP with Caddy and Let's Encrypt TLS.

---

# Testing

Run the automated test battery:

```powershell
# 1. Rust backend unit & integration tests (26 targets, 108 unit tests)
cd E:\MediaServer\rust
cmd /c "e:\MediaServer\scripts\cargo.bat test --no-fail-fast -- --test-threads=1"

# 2. React frontend unit tests and production build verification
cd web
npm run test
npm run typecheck
npm run build
cd ..

# 3. Live client contract probe suites
python scripts/probe_android_api.py
python scripts/probe_phase_8_contracts.py
```

> **The Rust integration suite uses a dedicated `media_server_test` database**, never the production
> one. `AppConfig::from_env()` falls back to the production database when
> `MEDIA_SERVER_DATABASE_URL` is unset — and on this host it is — so tests must be built on
> `media_server_api::test_support::test_config()` instead. See
> [`docs/DEVELOPMENT_STATUS.md`](docs/DEVELOPMENT_STATUS.md) §4.

---

# License and Attribution

Intended for personal media streaming and home-lab deployment. Metadata and imagery provided by **The Movie Database (TMDb)**.
