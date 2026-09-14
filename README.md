# My Movies — Personal Media Server

A modern, lightweight Flask media server built for local LAN streaming and secure remote access behind CGNAT. Features on-demand HLS transcoding, TMDb metadata ingestion, dual-axis subtitle positioning, rich player telemetry, and a real-time **Connected Devices Telemetry Dashboard**.

---

## Key Features

### 🎬 Media Playback & Transcoding
- **Direct Play & On-Demand HLS**: Direct byte-range streaming for MP4/AAC streams and automated on-demand HLS transcoding for MKV/HEVC.
- **AMD AMF support**: Optional AMD hardware H.264 encoding through FFmpeg AMF on Windows.
- **Transcode Progress Indicators**: Real-time progress badges on both details and player screens while background segmentation processes media.
- **Dual-Axis Subtitle Customization**: Local subtitle auto-discovery (`.srt`, `.vtt`) with in-memory conversion. Supports both horizontal alignment (*left*, *center*, *right*) and vertical elevation (*lowered*, *bottom*, *raised*, *middle*, *top*) to prevent overlap with playback controls.
- **Stats for Nerds (HUD)**: In-player technical telemetry overlay (`n` / `N` shortcut or HUD button) tracking frame drops (`getVideoPlaybackQuality()`), viewport vs native resolution, forward buffer calculation, and stream transcode state.
- **Playback Gestures & State Persistence**: Tap-to-reveal controls, non-clipping title badges, resume playback, playback speed, and throttled progress sync.

### 📱 Connected Devices Telemetry (`/devices`)
- **Device & Hardware Intelligence**: Identifies client device type (*Phone*, *Tablet*, *Desktop*), resolved OEM make & model (decoding Vivo/iQOO, Samsung Galaxy, Google Pixel, OnePlus, etc. via Chromium High-Entropy Client Hints), and OS version.
- **Network Path Detection**: Identifies whether a client connects via Localhost (`127.0.0.1`), Local LAN (`192.168.x.x`), or Remote Internet through Cloudflare Tunnel.
- **Network Telemetry**: Resolves client public IP, ISP/autonomous system organization, and local MAC address (via LAN ARP cache).
- **Real-Time Presence & Heartbeats**: Tracks active status using tab-visibility-aware keepalives and `pagehide` beacon telemetry with exact "Last Seen" timestamps and relative age.
- **Device Management**: Filter devices by *Active Now* or *Offline*, rename friendly device identifiers, inspect per-device watch history, or purge old device records.

### 📁 Library & Ingestion Management
- **Searchable Responsive Library**: Filter by genre, sort by recently added or rating, and pick up from *Continue Watching*.
- **Upload Flow with Telemetry**: Resumable upload pipeline with exponentially smoothed transfer speed and dynamic ETA countdown.
- **Dynamic Post-Upload Ingestion**: Animated status indicator showing backend probing, TMDb indexing, poster caching, and subtitle synchronization.
- **Safe Modal Dialogs**: Outside-touch immune confirmation dialogs for destructive actions (file purge, device removal).

---

## Architecture & Technology Stack

- **Backend**: Python 3 / Flask (Modular Blueprints: `api`, `pages`, `stream`)
- **Database**: SQLite (`media.db`) with automatic schema migrations
- **Transcoding**: FFmpeg & FFprobe on-demand HLS segmentation; optional AMD AMF hardware encoding on Windows
- **Metadata**: [The Movie Database (TMDb)](https://www.themoviedb.org/) API with local poster/backdrop caching
- **Production server**: Waitress on Windows; Gunicorn/systemd remains supported for Linux deployments
- **Remote Access**: Cloudflare Tunnel (`cloudflared`) compatible with CGNAT

## Current Windows Development

The current development workstation is Windows:

```text
Project:       C:\MediaServer
Media root:    C:\Flicks
Database:      C:\MediaServer\media.db
Venv:          C:\MediaServer\venv
Python:        3.14.3
FFmpeg:        9.0.1 with AMF
cloudflared:   C:\Cloudflared\cloudflared.exe
```

See:

- [`docs/WINDOWS_SETUP.md`](docs/WINDOWS_SETUP.md) — complete Windows environment, FFmpeg/AMF validation, Cloudflare setup, Git workflow, and troubleshooting notes.
- [`docs/DEVELOPMENT_STATUS.md`](docs/DEVELOPMENT_STATUS.md) — current implementation status and next-session handoff.
- [`AGENTS.md`](AGENTS.md) — instructions and state for coding agents.
- [`docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`](docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md) — detailed named-tunnel/CGNAT history.

---

## Quick Start

### 1. Installation

```bash
# Clone repository
git clone https://github.com/anis7t/media-server.git
cd media-server

# Linux
python3 -m venv venv
source venv/bin/activate

# Windows PowerShell
# python -m venv venv
# .\venv\Scripts\Activate.ps1

# Install dependencies
pip install -r requirements.txt
```

### 2. Configuration

Create a `.env` file in the project root. A safe template is provided as `.env.example`.

```ini
TMDB_API_TOKEN=your_tmdb_bearer_token_here
MEDIA_SERVER_MEDIA_ROOT=/path/to/your/media
MEDIA_SERVER_DATABASE=media.db
MEDIA_SERVER_BASE_DIR=/path/to/media-server
MEDIA_SERVER_ENABLE_AMF=0
```

On Windows, the current setup uses `C:\Flicks` as the media root and `C:\MediaServer` as the project/base directory. Set `MEDIA_SERVER_ENABLE_AMF=1` to enable AMD AMF encoding when supported by the installed FFmpeg build.

> [!NOTE]
> Never commit `.env` or your TMDb token. The real Windows `.env` is intentionally not stored in Git.

### 3. Ingestion (Optional)

```bash
python scanner.py
python posters.py
```

### 4. Running the Server

#### Development Mode

```bash
python app.py
```

#### Windows Production Mode

```powershell
.\venv\Scripts\Activate.ps1
python run_production.py
```

`run_production.py` uses Waitress, with port `8000` and 8 threads by default.

#### Linux Production / Systemd

```bash
systemctl --user start media-server.service
systemctl --user restart media-server.service
systemctl --user status media-server.service
```

---

## Remote Access (Cloudflare Tunnel)

The current named tunnel uses `media.anisparvez.in` and routes to the local application on `127.0.0.1:8000`.

The historical setup and detailed commands are documented in [`docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`](docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md).

Never commit Cloudflare tunnel tokens or credential JSON files.

---

## Testing

Run the automated pytest suite:

```bash
python -m pytest tests/
```

The test suite covers:
- App factory, database migrations, and routing endpoints
- Device tracking, client hints resolution, and heartbeat lifecycle
- Subtitle parsing, cue elevation, and WebVTT conversion
- HLS transcode caching and seek handling

---

## Current Development Focus

The active feature branch is `gpu-amf-transcoding`, based on the known-good baseline `4ce82da`. AMD AMF encoding has been validated, including a real Media Server HLS process using `h264_amf`.

The next task is to explicitly bind AMF to the D3D11 adapter that was experimentally confirmed to select the Radeon RX 560X, followed by a separate investigation of the playback transcoding indicator that currently blinks repeatedly during playback.

Do not merge the feature branch into `testing` until those checks pass. See `docs/DEVELOPMENT_STATUS.md` for the exact sequence.

---

## License & Attribution

- Media metadata and imagery provided by [The Movie Database (TMDb)](https://www.themoviedb.org/).
- Built for private personal and local network media streaming.
