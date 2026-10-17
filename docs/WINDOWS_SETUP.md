# Windows Development & Production Setup

This document records the complete Windows development and production environment for the Media Server on Windows 11.

---

## 1. Project Layout & Environment

- **Repository Root:** `E:\MediaServer`
- **Media Library:** `D:\Flicks`
- **Archive Storage Pool:** `D:\Flicks\.archive`
- **Upload Staging:** `D:\Flicks\.uploads`
- **Deleted-Source Staging:** `D:\Flicks\.deleted`
- **Transcode Cache:** `E:\MediaServer\cache\hls` (Storage Pool telemetry aggregates `D:` + `E:`)
- **SQLite Database:** `E:\MediaServer\media.db`
- **Environment File:** `E:\MediaServer\.env`
- **Virtual Environment:** `E:\MediaServer\venv`
- **Python Version:** 3.14.3
- **FFmpeg:** 9.0.1 essentials build with AMD AMF & D3D11va
- **cloudflared:** 2026.9.1 (`C:\Cloudflared\bin\cloudflared.exe`)

```powershell
cd E:\MediaServer
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

The system runs completely detached as persistent Windows Services that survive reboots without active user login.

> **C:-resident hosting & Autonomous Rust Operation (2026-10-17).** The application lives on the removable volume `E:`. NSSM runs from `C:\MediaServer\bin\nssm.exe` and PostgreSQL binaries from `C:\postgres` (data on `E:\pgdata`). A 5-minute watchdog (`MediaServerWatchdog` scheduled task running `scripts\service_watchdog.ps1`) strictly maintains PostgreSQL (`MediaServerPG`) and the unified Rust/React service (`MediaServerRust`), while ignoring the decommissioned Flask service.

### A. MediaServerRust (Rust Axum API & React Web SPA — Primary Production Service)
Registered using NSSM (Non-Sucking Service Manager):
- **Service Name:** `MediaServerRust`
- **Display Name:** `Media Server API (Rust/Axum)`
- **Startup Type:** `Automatic`
- **Service Wrapper:** `C:\MediaServer\bin\nssm.exe`
- **Binary:** `E:\MediaServer\rust\target\release\media-server-api.exe`
- **Port:** `8000` (Unified production port; port 8001 is fully retired)
- **Working Directory:** `E:\MediaServer`
- **Log Files:** `E:\MediaServer\logs\rust_api.log` and `rust_api_error.log` (auto-rotated at 10 MB)
- **Environment:** Injected `PATH` containing FFmpeg, PostgreSQL and WinGet links, `MEDIA_SERVER_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/media_server`, `MEDIA_SERVER_STATIC_DIR=E:\MediaServer\web\dist`.

#### Harmonized Management Scripts:
- **Unified Service Restart:** `scripts\restart_service.bat` (elevates to Administrator via UAC, restarts `MediaServerRust`, and runs status diagnostic)
- **Compatibility Restart Alias:** `scripts\restart_rust_service.bat` (delegates to `restart_service.bat`)
- **Authoritative Diagnostic:** `powershell -ExecutionPolicy Bypass -File scripts\service_status.ps1` (verifies `MediaServerRust` on `:8000`, `MediaServerPG` on `:5432`, `Cloudflared`, reports `MediaServer` stopped, checks local SPA, API, tunnel, active transcodes, and log tails)
- **Compatibility Status Alias:** `powershell -ExecutionPolicy Bypass -File scripts\rust_service_status.ps1` (delegates to `service_status.ps1`)
- **Install / Reinstall:** `scripts\install_rust_service.bat` (Run as Administrator; defaults to port 8000)
- **Uninstall:** `scripts\uninstall_rust_service.bat` (Run as Administrator)

### B. MediaServer (Legacy Waitress/Flask WSGI — Decommissioned)
- **Service Name:** `MediaServer`
- **Display Name:** `Media Server WSGI (Waitress)`
- **Status:** **Decommissioned & Stopped** (`Startup Type: Manual`)
- **Note:** Port 8000 is now owned by `MediaServerRust`. The legacy service is retained temporarily in a stopped state for final code retirement in Slice 7E. It is decoupled from the watchdog and will not auto-start.

### B2. MediaServerPG (PostgreSQL 18.4)
Registered via `pg_ctl register` (`scripts\move_pg_to_c.ps1`):
- **Service Name:** `MediaServerPG`
- **Startup Type:** `Automatic`, with SCM recovery actions (restart x3 with backoff)
- **Account:** `NT AUTHORITY\NetworkService` — postmaster refuses to run as an administrator/LocalSystem account
- **Service Wrapper:** `C:\postgres\pgsql\bin\pg_ctl.exe runservice -N MediaServerPG -D E:\pgdata -w`
- **Data Directory:** `E:\pgdata` (NetworkService granted full control on the tree)
- **Port:** `5432`, database `media_server`
- **Management Scripts:** `scripts\start_postgres.bat`, `scripts\stop_postgres.bat` (prefer `C:\postgres`, fall back to `E:\postgres`)
- **Database Backup:** `scripts\backup_postgres.bat` (invokes `scripts\backup_postgres.ps1`, generating timestamped, compressed custom-format dumps in `E:\MediaServer\backups\postgres\` with 7-backup automatic rotation pruning)

### C. Cloudflared (Remote Named Tunnel)
Runs as an automatic Windows Service pointing to `C:\Users\<USER>\.cloudflared\config.yml`:
- **Hostname:** `your-media-hostname.example.com`
- **Origin:** `http://127.0.0.1:8000`

If DNS retains stale CNAME records from an earlier tunnel, update dynamically using:
```powershell
cloudflared.exe tunnel route dns --overwrite-dns <TUNNEL_NAME_OR_UUID> your-media-hostname.example.com
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
  - `D:\Flicks\.deleted`: **Staging area for deleted source files** (via `delete_source` retention policy). When a transcoded movie's source is deleted, it's moved here instead of truncated to 0 bytes, preserving recoverability until manual cleanup.
  - `E:\MediaServer\cache\hls`: Scratch shelter for in-progress transcode chunk generation and high-speed SSD playback of 100% verified HLS segments.
  - Python `shutil.move()` ensures safe atomic cross-drive file relocation across Windows filesystem boundaries without `[WinError 17]`.
  - Automated orphaned cache purge cleans unreferenced chunks on startup and every 2 hours via background daemon.

---

## 5. Active Next Steps & Engineering Tasks

1. **Production Concurrency Tuning & Benchmarks:**
   Benchmark Waitress worker and thread pools against remote stream latency, Cloudflare tunnel limits, and concurrent multi-device playback.
2. **Cloudflare Media Delivery Review:**
   Review Cloudflare service-specific video delivery policies before scaling remote public distribution.

