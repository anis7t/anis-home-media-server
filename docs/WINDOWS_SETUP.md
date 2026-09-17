# Windows Development & Production Setup

This document records the complete Windows development and production environment for the Media Server on Windows 11.

---

## 1. Project Layout & Environment

- **Repository Root:** `C:\MediaServer`
- **Media Library:** `C:\Flicks`
- **Archive Storage Pool:** `D:\Flicks\.archive` (215+ GB free storage pool on D:)
- **SQLite Database:** `C:\MediaServer\media.db`
- **Environment File:** `C:\MediaServer\.env`
- **Virtual Environment:** `C:\MediaServer\venv`
- **Python Version:** 3.14.3
- **FFmpeg:** 9.0.1 essentials build with AMD AMF & D3D11va
- **cloudflared:** 2026.9.1 (`C:\Cloudflared\bin\cloudflared.exe`)

```powershell
cd C:\MediaServer
.\venv\Scripts\Activate.ps1
python --version
pip install -r requirements.txt
```

---

## 2. Hardware Acceleration & Dual-GPU Setup

The Windows host features two AMD graphics processors:
- **Discrete GPU:** AMD Radeon RX 560X (4GB VRAM) — Task Manager GPU 0 / FFmpeg `dx11:1`
- **Integrated GPU:** AMD Radeon Vega 8 Graphics — Task Manager GPU 1 / FFmpeg `dx11:0`

> **Note on Adapter Numbering:** Windows Task Manager GPU indices are inverted compared to FFmpeg D3D11 adapter indices. Always verify with direct FFmpeg hardware device probe commands:
> ```powershell
> ffmpeg -hide_banner -init_hw_device d3d11va=dx11:1 -init_hw_device amf=amf@dx11 -filter_hw_device amf ...
> ```

### Dynamic Multi-GPU Transcoding Architecture
- Managed by `app/services/gpu_service.py` and `app/services/chunk_transcode_service.py`.
- Both GPUs transcode separate, keyframe-aligned segments concurrently.
- Real-time engine loads for both GPUs are tracked via Windows Performance Counters / PyNVML and displayed on the System Telemetry HUD.
- Polling cadence is set to 1 second for live progress, speed, and ETA calculations.

---

## 3. Persistent Windows Services

The system runs completely detached as two persistent Windows Services that survive reboots without active user login:

### A. MediaServer (Waitress WSGI)
Registered using NSSM (Non-Sucking Service Manager):
- **Service Name:** `MediaServer`
- **Display Name:** `Media Server WSGI (Waitress)`
- **Startup Type:** `Automatic`
- **Binary:** `C:\MediaServer\venv\Scripts\python.exe`
- **Arguments:** `run_production.py`
- **Working Directory:** `C:\MediaServer`
- **Log Files:** `C:\MediaServer\logs\waitress.log` and `waitress_error.log` (auto-rotated at 10 MB)
- **Environment:** Injected `PATH` containing FFmpeg binaries.

#### Management Scripts:
- Install / Reinstall: `scripts\install_service.bat` (Run as Administrator)
- Uninstall: `scripts\uninstall_service.bat` (Run as Administrator)
- Restart: `scripts\restart_service.bat`
- Health Diagnostic: `powershell -ExecutionPolicy Bypass -File scripts\service_status.ps1`

### B. Cloudflared (Remote Named Tunnel)
Runs as an automatic Windows Service pointing to `C:\Users\<USER>\.cloudflared\config.yml`:
- **Hostname:** `media.anisparvez.in`
- **Origin:** `http://127.0.0.1:8000`

If DNS retains stale CNAME records from an earlier tunnel, update dynamically using:
```powershell
cloudflared.exe tunnel route dns --overwrite-dns <TUNNEL_NAME_OR_UUID> media.anisparvez.in
```

---

## 4. UI & Playback Polish

- **Live Seek Hover Previews:** Frame thumbnails are dynamically extracted on-demand via `app/services/preview_service.py` using fast input-seeking (`-ss` before `-i`) and cached in `cache/previews/`.
- **Player Controls:** 36px circular control buttons, prominent 21px SVG icons, 4px vertical breathing room in `.controls-row` preventing top focus truncation.
- **Native Dark Selects:** `color-scheme: dark !important;` prevents white-on-white dropdown rendering in Windows Chromium.
- **Hold-to-Speed Removed:** Fast-forward hold gestures removed from pointer listeners and modal cheat-sheet.
- **Upload Lifecycle:** Abort button hidden immediately upon 100% upload completion; animated cycling card shows background ingestion status (*Probing...*, *TMDb...*, *Posters...*, *Subtitles...*).
- **Dual-Disk Tiered Storage Architecture:**
  - `D:\Flicks\.uploads`: Staging area for resumable chunked uploads on secondary high-capacity drive, protecting primary `C:` SSD from 10–20 GB upload exhaustion.
  - `D:\Flicks`: Main raw video storage repository for completed uploads.
  - `D:\Flicks\.archive`: Cold source retention repository on secondary drive (215+ GB free pool), automatically populated when movies reach 100% verified HLS transcoding or via one-click **📦 Archive** action on `/manage`.
  - `C:\MediaServer\cache\hls`: Scratch shelter for in-progress transcode chunk generation and high-speed SSD playback of 100% verified HLS segments.
  - Python `shutil.move()` ensures safe atomic cross-drive file relocation across Windows filesystem boundaries without `[WinError 17]`.
  - Automated orphaned cache purge cleans unreferenced chunks on startup and every 2 hours via background daemon.

---

## 5. Active Next Steps & Engineering Tasks

1. **Production Concurrency Tuning & Benchmarks:**
   Benchmark Waitress worker and thread pools against remote stream latency, Cloudflare tunnel limits, and concurrent multi-device playback.
2. **Cloudflare Media Delivery Review:**
   Review Cloudflare service-specific video delivery policies before scaling remote public distribution.

