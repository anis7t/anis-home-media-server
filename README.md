# My Movies — Personal Media Server

A modern, lightweight Flask media server built for local LAN streaming and secure remote access behind CGNAT. Features on-demand HLS transcoding, TMDb metadata ingestion, dual-axis subtitle positioning, rich player telemetry, and a real-time **Connected Devices Telemetry Dashboard**.

---

## Key Features

### 🎬 Media Playback & Transcoding
- **Direct Play & On-Demand HLS**: Direct byte-range streaming for MP4/AAC streams and automated on-demand HLS transcoding for MKV/HEVC.
- **Transcode Progress Indicators**: Real-time progress badges on both details and player screens while background segmentation processes media.
- **Dual-Axis Subtitle Customization**: Local subtitle auto-discovery (`.srt`, `.vtt`) with in-memory conversion. Supports both horizontal alignment (*left*, *center*, *right*) and vertical elevation (*lowered*, *bottom*, *raised*, *middle*, *top*) to prevent overlap with playback controls.
- **Stats for Nerds (HUD)**: In-player technical telemetry overlay (`n` / `N` shortcut or HUD button) tracking frame drops (`getVideoPlaybackQuality()`), viewport vs native resolution, forward buffer calculation, and stream transcode state.
- **Playback Gestures & State Persistence**: Tap-to-reveal controls, non-clipping title badges, resume playback, playback speed, and throttled progress sync.

### 📱 Connected Devices Telemetry (`/devices`)
- **Device & Hardware Intelligence**: Identifies client device type (*Phone*, *Tablet*, *Desktop*), resolved OEM make & model (decoding Vivo/iQOO, Samsung Galaxy, Google Pixel, OnePlus, etc. via Chromium High-Entropy Client Hints), and OS version.
- **Network Path Detection**: Identifies whether a client connects via Localhost (`127.0.0.1`), Local LAN (`192.168.x.x`), or Remote Internet through Cloudflare Tunnel (`*.trycloudflare.com`).
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
- **Transcoding**: FFmpeg & FFprobe on-demand HLS segmentation
- **Metadata**: [The Movie Database (TMDb)](https://www.themoviedb.org/) API with local poster/backdrop caching
- **Process Supervision**: Systemd user service (`media-server.service`)
- **Remote Access**: Cloudflare Quick Tunnel (`cloudflared`) compatible with Airtel CGNAT

---

## Quick Start

### 1. Installation

```bash
# Clone repository
git clone https://github.com/anis7t/media-server.git
cd media-server-1

# Create and activate virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

### 2. Configuration

Create a `.env` file in the project root:

```ini
TMDB_API_TOKEN=your_tmdb_api_bearer_token_here
MEDIA_SERVER_MEDIA_ROOT=/home/iamroot/Media/Movies
MEDIA_SERVER_DATABASE=media.db
MEDIA_SERVER_BASE_DIR=/home/iamroot/media-server-1
```

> [!NOTE]
> Never commit `.env` or your TMDb token. Default media path is `/home/iamroot/Media/Movies`.

### 3. Ingestion (Optional)

```bash
python scanner.py     # Discover files and query TMDb metadata
python posters.py     # Download and cache posters/backdrops
```

### 4. Running the Server

#### Development Mode
```bash
python app.py
```
The server binds to `0.0.0.0:8000` (accessible at `http://127.0.0.1:8000` and `http://<LAN_IP>:8000`).

#### Production Systemd Service
The server can run as a background systemd user service:

```bash
systemctl --user start media-server.service    # Start service
systemctl --user restart media-server.service  # Restart service
systemctl --user status media-server.service   # View logs and status
```

---

## Remote Access (Cloudflare Tunnel)

To access the server securely from outside your home network without router port forwarding (ideal for CGNAT connections):

```bash
cloudflared tunnel --url http://127.0.0.1:8000
```

Cloudflare generates a temporary URL:
```
https://<random-subdomain>.trycloudflare.com
```

- When remote clients access the tunnel, the server identifies the connection as `Cloudflare Tunnel` under `/devices`.
- Client requests report Cloudflare IP headers (`CF-Connecting-IP`, `X-Forwarded-For`), allowing true remote IP and ISP resolution.
- For full architecture details, refer to [`docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`](docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md).

---

## Testing

Run the automated pytest test suite:

```bash
python3 -m pytest tests/
```

The test suite covers:
- App factory, database migrations, and routing endpoints
- Device tracking, client hints resolution, and heartbeat lifecycle
- Subtitle parsing, cue elevation, and WebVTT conversion
- HLS transcode caching and seek handling

---

## License & Attribution

- Media metadata and imagery provided by [The Movie Database (TMDb)](https://www.themoviedb.org/).
- Built for private personal and local network media streaming.
