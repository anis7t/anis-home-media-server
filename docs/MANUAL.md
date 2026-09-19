# User Manual & Operator Guide — Anis' Home Media Server

Welcome to **Anis' Home Media Server**, a high-performance, self-hosted personal streaming suite designed for streaming private movie libraries across local networks and remote connections.

This document serves as the official user manual and operator guide covering playback, player gestures, dual-GPU acceleration, subtitle management, resumable uploads, storage tiering, and device telemetry.

---

## Table of Contents

1. [Accessing the Server](#1-accessing-the-server)
   - [Local Network Streaming](#local-network-streaming)
   - [Remote Access via Cloudflare Named Tunnel](#remote-access-via-cloudflare-named-tunnel)
   - [Progressive Web App (PWA) Installation](#progressive-web-app-pwa-installation)
2. [Browsing & Library Navigation](#2-browsing--library-navigation)
   - [Search & Filtering](#search--filtering)
   - [Continue Watching Rail](#continue-watching-rail)
   - [Movie Details, Cast & Codecs](#movie-details-cast--codecs)
3. [Video Player & Touch Controls](#3-video-player--touch-controls)
   - [YouTube-Style Layered Seekbar](#youtube-style-layered-seekbar)
   - [Live Hover Thumbnail Previews](#live-hover-thumbnail-previews)
   - [Touch Gestures & Mobile Controls](#touch-gestures--mobile-controls)
   - [Aspect Ratio & Hardware Rotation](#aspect-ratio--hardware-rotation)
4. [Keyboard Shortcuts Cheatsheet](#4-keyboard-shortcuts-cheatsheet)
5. [Streaming Architecture: Direct Play vs Multi-GPU Transcoding](#5-streaming-architecture-direct-play-vs-multi-gpu-transcoding)
   - [Direct Play (Zero-Copy RFC 7233)](#direct-play-zero-copy-rfc-7233)
   - [Dynamic Multi-GPU Chunked Transcoding](#dynamic-multi-gpu-chunked-transcoding)
   - [Live Telemetry & Stats for Nerds](#live-telemetry--stats-for-nerds)
6. [Subtitles & Dual-Axis Positioning](#6-subtitles--dual-axis-positioning)
   - [Dual-Axis Customization](#dual-axis-customization)
   - [In-Player & Details Subtitle Upload](#in-player--details-subtitle-upload)
   - [Intelligent Language Auto-Detection](#intelligent-language-auto-detection)
7. [Uploading Media & Metadata Ingestion](#7-uploading-media--metadata-ingestion)
   - [Resumable Chunked Transfers](#resumable-chunked-transfers)
   - [Automated TMDb Enrichment](#automated-tmdb-enrichment)
   - [Forensic Media Resolver](#forensic-media-resolver)
8. [Storage Retention & Cache Management](#8-storage-retention--cache-management)
   - [Dual-Drive Storage Tiering (C: SSD + D: HDD)](#dual-drive-storage-tiering-c-ssd--d-hdd)
   - [Configurable Retention Policies](#configurable-retention-policies)
   - [Safe Orphaned Cache Purging](#safe-orphaned-cache-purging)
9. [Connected Devices Dashboard](#9-connected-devices-dashboard)
   - [Chromium High-Entropy Client Hints](#chromium-high-entropy-client-hints)
   - [Friendly Renaming & Watch History](#friendly-renaming--watch-history)
10. [Troubleshooting & FAQs](#10-troubleshooting--faqs)

---

## 1. Accessing the Server

Anis' Home Media Server can be streamed from any modern web browser without installing custom client software.

### Local Network Streaming
- **Origin Address:** `http://127.0.0.1:8000` (on the host machine) or `http://<LAN-IP>:8000` from other devices on the same Wi-Fi network.
- **Benefits:** Maximum fidelity, zero WAN bandwidth limits, and instant direct playback.

### Remote Access via Cloudflare Named Tunnel
- **Public Address:** `https://media.anisparvez.in`
- **Architecture:** Powered by Cloudflare Named Tunnels (`cloudflared`). The tunnel creates an outbound TLS connection from your host machine to Cloudflare's edge network, bypassing CGNAT and ISP firewall restrictions without opening router ports.

### Progressive Web App (PWA) Installation
The server provides a certified PWA manifest and vector SVG brand icon for native app feel:
- **iOS (Safari):** Open `https://media.anisparvez.in`, tap the **Share** button, and select **Add to Home Screen**.
- **Android (Chrome):** Tap the menu (`⋮`) and select **Install App** or tap the install banner.
- **Desktop (Chrome/Edge):** Click the **Install** button on the right side of the URL bar.

---

## 2. Browsing & Library Navigation

The library interface (`/`) organizes your movie collection with an obsidian glass aesthetic:

- **Instant Search:** Type any title, year, or genre into the search bar. Filtering occurs live across your metadata.
- **Continue Watching Rail:** Media you began streaming (between 10 seconds and completion) appears in a swipeable top rail. Progress bars indicate exactly how far you watched. Resuming starts from your saved position with millisecond accuracy.
- **Movie Details Hero (`/movie/<filename>`):**
  - High-resolution TMDb posters and backdrops.
  - Runtime, vote average ratings, certification age rating, and genre tags.
  - Full plot synopsis and director/writer/cast credits.
  - Technical Media Specs Card: video container, resolution, display aspect ratio, video codec/profile, audio codec, channels, sample rate, and total file size.

---

## 3. Video Player & Touch Controls

The custom HTML5 player (`/watch/<filename>`) provides desktop-grade playback and responsive mobile controls.

### YouTube-Style Layered Seekbar
The seekbar visualizes four independent layers:
1. **Played Fill:** Crimson red progress bar showing current playback position.
2. **Buffered Progress:** Semi-transparent track showing browser-buffered audio/video chunks.
3. **Ghost Hover Scrubber:** Follows cursor/pointer movement with accurate timestamps.
4. **Buffered Commit:** Byte-range `currentTime` commits strictly when you release your pointer (`pointerup`), preventing network flooding during scrubbing.

### Live Hover Thumbnail Previews
When you hover or scrub across the seekbar, the server's input-seeking thumbnail engine (`preview_service.py`) dynamically extracts high-definition frame thumbnails from the video and caches them in `cache/previews/` for zero-lag subsequent lookups.

### Touch Gestures & Mobile Controls
- **Tap-to-Reveal:** Tapping anywhere on the video canvas reveals the controls bar without accidentally pausing playback.
- **Double-Tap Seeking:** Double-tap the left 30% of the screen to seek backward 10s; double-tap the right 30% to seek forward 10s.
- **Mobile Controls Rail:** On smartphones, essential controls (Restart, Mute, Speed, Subtitles, Aspect, Rotate, PiP, Nerd Stats) sit in a swipeable horizontal rail, keeping controls accessible without vertical clutter.
- **Elapsed vs Remaining Time:** Tap the elapsed time on the bottom left (e.g. `14:20`) to toggle between elapsed time and negative countdown time (e.g. `-1:22:10`).

### Aspect Ratio & Hardware Rotation
- **Aspect Ratio Button (`a`):** Cycles between *Best Fit (Contain)*, *16:9 Wide*, *4:3 Classic*, *Crop (Fill)*, and *Original*.
- **Rotate Screen (`r`):** Locks screen orientation to landscape or cycles hardware CSS video rotation by 90°.

---

## 4. Keyboard Shortcuts Cheatsheet

| Shortcut | Action | Description |
|---|---|---|
| <kbd>Space</kbd> / <kbd>k</kbd> | Play / Pause | Toggle playback state |
| <kbd>Home</kbd> / <kbd>0</kbd> | Replay from start | Instantly replay from `0:00` |
| <kbd>←</kbd> / <kbd>→</kbd> | Seek ±5 seconds | Fine-grained timestamp scrubbing |
| <kbd>j</kbd> / <kbd>l</kbd> | Seek ±10 seconds | Rapid skipping |
| <kbd>1</kbd> – <kbd>9</kbd> | Jump 10%–90% | Timeline percentage navigation |
| <kbd>f</kbd> | Fullscreen | Toggle native full-screen mode |
| <kbd>m</kbd> | Mute / Unmute | Silence or restore audio output |
| <kbd>↑</kbd> / <kbd>↓</kbd> | Volume ±5% | Step volume up or down |
| <kbd>c</kbd> | Toggle Subtitles | Turn captions on or off |
| <kbd>&lt;</kbd> / <kbd>&gt;</kbd> | Playback Speed | Step between 0.75×, 1×, 1.25×, 1.5×, 2× |
| <kbd>a</kbd> | Aspect Ratio | Cycle fit, crop, 16:9, 4:3, original |
| <kbd>r</kbd> | Rotate Screen | Toggle 90° orientation |
| <kbd>p</kbd> / <kbd>i</kbd> | Picture-in-Picture | Detach video to floating OS window |
| <kbd>n</kbd> | Stats for Nerds | Toggle telemetry and GPU load HUD |
| <kbd>?</kbd> | Shortcuts Help | View on-screen shortcut modal |

---

## 5. Streaming Architecture: Direct Play vs Multi-GPU Transcoding

```text
Browser / Client (Desktop, Phone, Tablet)
         │
         ▼
Cloudflare Named Tunnel (media.anisparvez.in)
         │
         ▼
Waitress WSGI (127.0.0.1:8000) [NSSM Service]
         │
         ▼
Flask Media Routing Layer (app/routes/media.py)
   ├── Direct Stream (MP4/WebM) ──► RFC 7233 Zero-Copy Range Delivery
   └── Incompatible (MKV/HEVC)  ──► Dynamic Multi-GPU Chunk Transcoder
                                      ├── Worker 0: AMD Radeon RX 560X (dx11:1)
                                      └── Worker 1: AMD Radeon Vega 8 (dx11:0)
```

### Direct Play (Zero-Copy RFC 7233)
Compatible files (MP4, M4V, WebM with H.264 video and AAC audio) stream directly via `send_file(conditional=True, etag=True)`. The operating system kernel performs zero-copy socket transfers, bypassing transcoding entirely and enabling instantaneous seeking.

### Dynamic Multi-GPU Chunked Transcoding
For containers or codecs browsers cannot decode natively (e.g., MKV container, HEVC / H.265 video):
1. **Dynamic Chunk Partitioning:** `chunk_transcode_service.py` segments the video into keyframe-aligned timeline chunks.
2. **Concurrent Hardware Workers:** Chunk jobs are dispatched across available GPU adapters:
   - Discrete **AMD Radeon RX 560X** (`dx11:1`)
   - Integrated **AMD Radeon Vega 8** (`dx11:0`)
3. **Monotonic Presentation Timestamps:** Workers apply `-output_ts_offset` to guarantee zero timeline drift across chunk boundaries.
4. **Progressive HLS Playlist:** Playback begins within seconds using `#EXT-X-PLAYLIST-TYPE:EVENT` while the remainder transcodes in the background.

### Live Telemetry & Stats for Nerds
Press <kbd>n</kbd> in the player to open **Stats for Nerds**, reporting:
- Dropped frames vs total rendered frames via `getVideoPlaybackQuality()`.
- Stream type (`Direct Stream`, `HLS.js fMP4`, or `Transcoded MP4`).
- Forward buffer length (seconds).
- Active GPU engine utilization.

---

## 6. Subtitles & Dual-Axis Positioning

### Dual-Axis Customization
Open the Subtitle Settings modal (gear icon `⚙` or <kbd>c</kbd>) to configure:
- **Horizontal Alignment:** `Center` (default), `Left`, `Right`.
- **Vertical Position:** `Lowered Bottom` (default), `Bottom`, `Raised`, `Middle`, `Top`.
- **Cue Elevation:** Cues automatically elevate above the player controls bar to prevent overlapping buttons during playback.
- **Appearance:** Text color (White, Yellow, Cyan, Green, Magenta), background opacity (0% to 100%), and font size scaling.

### In-Player & Details Subtitle Upload
Upload sidecar `.srt` or `.vtt` files directly from:
- The **Movie Details** page (`/movie/<filename>`).
- Inside the player via **Subtitle Settings modal → Upload**.
Uploaded files are saved alongside the video file and immediately become available as an active selectable track without restarting playback.

### Intelligent Language Auto-Detection
The server's subtitle engine analyzes Unicode script characters and NLP word frequency:
- Detects Devanagari (Hindi), Hanzi (Chinese), Cyrillic (Russian), Arabic, Bengali, Japanese (Hiragana/Katakana), Korean (Hangul), and Latin languages.
- Renames uploaded files into the canonical format: `<movie_name>_<detected_lang>_<counter>.<ext>`.

---

## 7. Uploading Media & Metadata Ingestion

### Resumable Chunked Transfers
1. Click **Upload** in the top navigation header on any page.
2. Drag and drop any video file (`.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`).
3. Optional: Provide a Movie Title in the rename field if the file has an obscure name (e.g. `1000403712.mkv`).
4. Click **Upload Media**. The client transfers data in staged chunks with exponential moving average speed smoothing and remaining ETA.

### Automated TMDb Enrichment
Once the upload finishes, the server's background ingestion worker:
1. Probes technical video and audio parameters with `ffprobe`.
2. Queries the TMDb API for official movie title, release year, tagline, synopsis, cast, ratings, and backdrop artwork.
3. Automatically caches high-resolution artwork and updates the SQLite database.

### Forensic Media Resolver
If a file has a non-standard name, the forensic resolver (`media_resolver.py`) inspects parent directories, release tags, and container metadata to pinpoint the correct TMDb match automatically.

---

## 8. Storage Retention & Cache Management

### Dual-Drive Storage Tiering (C: SSD + D: HDD)
- **Fast NVMe SSD (`C:\`):** Hosts the operating system, SQLite database (`media.db`), live seek preview thumbnails (`cache/previews`), and completed HLS transcode streams (`cache/hls`).
- **Mass Storage Drive (`D:\Flicks`):** Dedicated to high-capacity cold storage, holding raw movie files, upload staging (`D:\Flicks\.uploads`), and source archives (`D:\Flicks\.archive`).

### Configurable Retention Policies
In **My Library (`/manage`)**, configure post-transcode policies:
- `keep` — Retain both raw source video and HLS transcoded cache indefinitely.
- `archive` — Move cold source video to `.archive` on secondary storage to free primary space while keeping HLS streams active.
- `purge_cache` — Delete HLS cache after playback completes, freeing SSD headroom.

### Safe Orphaned Cache Purging
Click **Purge Orphaned Caches** on `/manage` to reconcile cache directories against current media files. The engine terminates any lingering FFmpeg processes safely on Windows and removes stale transcode directories with zero risk of database corruption.

---

## 9. Connected Devices Dashboard

Navigate to `/devices` to view all active and historical client connections:

- **Client Hints Hardware Decoding:** Identifies exact device models (e.g. *Apple iPhone 15 Pro*, *Samsung Galaxy S24 Ultra*, *Google Pixel 8 Pro*) via Chromium High-Entropy Client Hints (`Sec-CH-UA-Model`).
- **Network Path Classification:** Classifies client connections as **Local LAN** or **Remote WAN** with public IP, reverse DNS, and ISP organization.
- **Friendly Renaming:** Give any device a custom human-readable name (e.g. *"Living Room TV"* or *"Anis' MacBook Air"*).
- **Per-Device Watch History:** Review what each device watched, last active timestamps, and completion rates.

---

## 10. Troubleshooting & FAQs

### Why does an MKV file take 3–5 seconds to begin playing?
Browsers do not natively play MKV containers. When you press play, the server's dual-GPU engine starts converting the file to browser-compatible fMP4 HLS segments. Playback begins as soon as the first 3 seconds are ready, while the rest encodes in the background.

### Subtitles are overlapping player controls. How do I adjust them?
Click the gear icon (<code>⚙</code>) in the player controls or press <kbd>c</kbd> to open Subtitle Settings. Set **Vertical Position** to *Raised Bottom* or *Middle*.

### Video is distorted or letterboxed improperly on my ultrawide / tablet screen.
Press <kbd>a</kbd> or click the **Aspect Ratio** button in the player controls to cycle through *Best Fit*, *16:9*, *4:3*, and *Crop (Zoom)*.

### How do I refresh library metadata after renaming a file?
Click **Scan Library** in the top navigation header or wait for the automatic 4-hour background TMDb refresh worker.

---

*© 2026 Anis' Home Media Server. Designed and built with Flask, Waitress, FFmpeg, and Cloudflare Named Tunnels.*
