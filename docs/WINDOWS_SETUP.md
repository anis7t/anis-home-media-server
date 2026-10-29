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
- **PostgreSQL Data:** `E:\pgdata` (binaries at `C:\postgres`)
- **Environment File:** `E:\MediaServer\.env`
- **Rust Toolchain:** 1.85+ (MSRV 2021 edition)
- **Node.js:** 20+ (for the `web/` React SPA build)
- **FFmpeg:** 9.0.1 essentials build with AMD AMF & D3D11va
- **Caddy:** `E:\MediaServer\bin\caddy_custom.exe` (Cloudflare DNS module)

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
- Managed natively in Rust by `rust/src/transcode/` — `engine.rs`, `planner.rs`, `queue.rs`, `sweeper.rs` — with the AMF VPP filters in `rust/src/services/gpu.rs`.
- Both GPUs transcode separate, keyframe-aligned segments concurrently.
- Real-time engine loads for both GPUs are tracked via Windows Performance Counters and displayed on the System Telemetry HUD.
- Polling cadence is set to 1 second for live progress, speed, and ETA calculations.

---

## 3. Persistent Windows Services

The system runs completely detached as persistent Windows Services that survive reboots without active user login.

> **C:-resident hosting, Autonomous Rust Operation & Auto-Start on Mount (2026-10-30).** The application and database live on the removable volume `E:`. NSSM runs from `C:\MediaServer\bin\nssm.exe` and PostgreSQL binaries from `C:\postgres` (data on `E:\pgdata`). To eliminate the requirement for manual intervention when booting without the USB drive attached, the automated task **`MediaServerAutoStartOnMount`** runs non-interactively in the background as `SYSTEM` with `-WindowStyle Hidden` (invoking `C:\MediaServer\bin\auto_start_on_mount.ps1`). It triggers immediately upon Windows Event ID `1001` (`Microsoft-Windows-StorageVolume/Operational`, Volume Arrived) and includes a repeating 1-minute fallback safety net. When drive `E:\pgdata` is detected, it automatically starts `MediaServerPG` and `MediaServerRust` within 3–4 seconds.

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
- **Authoritative Diagnostic:** `powershell -ExecutionPolicy Bypass -File scripts\service_status.ps1` (verifies `MediaServerRust` on `:8000`, `MediaServerPG` on `:5432`, `MediaServerCaddy` on `:80/:443`, reports decommissioned `MediaServer`/`Cloudflared`, checks local SPA, API, public ingress, active transcodes, and log tails)
- **Compatibility Status Alias:** `powershell -ExecutionPolicy Bypass -File scripts\rust_service_status.ps1` (delegates to `service_status.ps1`)
- **Install / Reinstall:** `scripts\install_rust_service.bat` (Run as Administrator; defaults to port 8000)
- **Uninstall:** `scripts\uninstall_rust_service.bat` (Run as Administrator)

### B. MediaServer (Legacy Waitress/Flask WSGI — Decommissioned)
- **Service Name:** `MediaServer`
- **Display Name:** `Media Server WSGI (Waitress)`
- **Status:** **Decommissioned & Stopped** (`Startup Type: Manual`)
- **Note:** Port 8000 is now owned by `MediaServerRust`. The legacy service is retained as an inert, Manual-start registration and will not auto-start; removing it is the owner's call.

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
- **Database Restore:** `scripts\restore_postgres.ps1` — verifies the archive, takes a pre-restore rollback point, restores via `pg_restore`, and reports row counts. Requires `-Confirm` to act, and `MediaServerRust` must be stopped first.
- **Scheduled Backup Task:** `MediaServerBackup` — daily at 03:00, runs as `SYSTEM`, logs to `E:\MediaServer\logs\backup_postgres.log`. Installed with `scripts\install_backup_task.bat`, removed with `scripts\uninstall_backup_task.ps1`. Full detail in [`docs/BACKUP_AND_RESTORE.md`](BACKUP_AND_RESTORE.md) §2.3.

### C. MediaServerCaddy (Reverse Proxy & TLS Terminator) — Active
Runs as an automatic NSSM Windows Service, fronting the Rust origin with a Let's Encrypt certificate. The SCM restart policy is restart x3 (5s/5s/10s), and NSSM restarts the Caddy process after 5s on an unexpected exit:
- **Service Name:** `MediaServerCaddy`
- **Service Wrapper:** `C:\MediaServer\bin\nssm.exe` (Automatic)
- **Caddy binary:** `C:\MediaServer\bin\caddy_custom.exe` (copied from `E:\MediaServer\bin\caddy_custom.exe` for `E:` resilience; built with the Cloudflare DNS module for the DNS-01 challenge)
- **Config:** `C:\MediaServer\Caddyfile` (copied from `E:\MediaServer\Caddyfile`) — **untracked / gitignored**, because it contains a live Cloudflare API token
- **Listener:** ports 80 and 443, TLS 1.3, reverse-proxying to `http://127.0.0.1:8000`
- **Hostname:** `media.anisparvez.in` → the Airtel Xstream Fiber static IP `171.50.176.119`
- **Router Port Forwarding:** only 443 and 80 reach the host. The `MediaServer` forward for 8000 was
  removed on 2026-10-20 — the origin must not be reachable from the internet over plain HTTP.
  Managed with [`scripts\router_port_forward.ps1`](../scripts/router_port_forward.ps1)
  (`-Action List | Remove | Add`).
- **Certificate:** Let's Encrypt, issued via an automated DNS-01 challenge, renewed in the background
- **Streaming:** unbuffered HTTP/2 and HTTP/3, and Server-Sent Events (`text/event-stream`) are proxied without delay — which the QR sign-in wait stream depends on

```text
media.anisparvez.in {
    tls {
        dns cloudflare <API_TOKEN>
    }
    reverse_proxy 127.0.0.1:8000
}
```

> **The Cloudflare named tunnel is decommissioned.** The `cloudflared` Windows service has been
> removed, and the Cloudflare DNS record for `media.anisparvez.in` is DNS-only, pointing straight at
> the static IP. Cloudflare is still used for **DNS hosting and the DNS-01 challenge only** — it is
> no longer in the traffic path.

---

## 4. UI & Playback Polish

- **Live Seek Hover Previews:** Frame thumbnails are dynamically extracted on demand by the native Rust `rust/src/services/preview_service.rs`, using fast input-seeking (`-ss` before `-i`) and cached in `cache/previews/`.
- **Player Controls:** 36px circular control buttons, prominent 21px SVG icons, 4px vertical breathing room in `.controls-row` preventing top focus truncation.
- **Native Dark Selects:** `color-scheme: dark !important;` prevents white-on-white dropdown rendering in Windows Chromium.
- **Hold-to-Speed Removed:** Fast-forward hold gestures removed from pointer listeners and modal cheat-sheet.
- **Upload Lifecycle:** Abort button hidden immediately upon 100% upload completion; animated cycling card shows background ingestion status (*Probing...*, *TMDb...*, *Posters...*, *Subtitles...*).
- **QR Device Sign-In Panel:** `/account` shows an OTT-style activation panel (QR image, 5-character code, countdown ring, manual URL) whenever the visitor is not signed in, so a TV or browser can be signed in from a phone. Full context in [`docs/QR_SIGNIN_WALKTHROUGH.md`](QR_SIGNIN_WALKTHROUGH.md).
- **Dual-Disk Tiered Storage Architecture:**
  - `D:\Flicks\.uploads`: Staging area for resumable chunked uploads on secondary high-capacity drive, protecting primary `C:` SSD from 10–20 GB upload exhaustion.
  - `D:\Flicks`: Main raw video storage repository for completed uploads.
  - `D:\Flicks\.archive`: Cold source retention repository on secondary drive (215+ GB free pool), automatically populated when movies reach 100% verified HLS transcoding or via one-click **📦 Archive** action on `/manage`.
  - `D:\Flicks\.deleted`: **Staging area for deleted source files** (via `delete_source` retention policy). When a transcoded movie's source is deleted, it's moved here instead of truncated to 0 bytes, preserving recoverability until manual cleanup.
  - `E:\MediaServer\cache\hls`: Scratch shelter for in-progress transcode chunk generation and high-speed SSD playback of 100% verified HLS segments.
  - Cross-drive file relocation uses `shutil.move()`-equivalent semantics in Rust with target-collision pre-unlinking, to avoid `[WinError 17]`.
  - Automated orphaned cache purge cleans unreferenced chunks on startup and every 2 hours via background daemon.

---

## 5. Active Next Steps & Engineering Tasks

1. **Close the public `:8000` origin forward.** — ✅ **DONE 2026-10-20**
   The router forwarded 443, 80 **and 8000**, so `http://171.50.176.119:8000/health` answered 200
   from the internet, bypassing Caddy and TLS entirely. The `MediaServer` rule was removed with
   [`scripts\router_port_forward.ps1`](../scripts/router_port_forward.ps1). Port 8000 is **no longer
   forwarded**; only 443 and 80 are. The origin is still reachable on the LAN
   (`http://192.168.1.16:8000`) and on loopback, which is what Caddy and the LAN clients use.
2. **Add `Secure` to the session cookie.** — ✅ **DONE 2026-10-20, conditionally**
   `AuthService::session_cookie()` now appends `Secure` **only when the request arrived over TLS**
   (`X-Forwarded-Proto: https`, which Caddy sets and overwrites). The flag cannot be unconditional:
   the LAN path is plain HTTP, and a browser refuses to store or send a `Secure` cookie over plain
   HTTP, so that would break LAN sign-in entirely. All five cookie sites now go through the shared
   helper.
3. **Pin a public base URL for the QR sign-in flow.** — ✅ **DONE 2026-10-20**
   `MEDIA_SERVER_PUBLIC_BASE_URL` (e.g. `https://media.anisparvez.in`) is set in the NSSM service
   environment and in `.env`. `get_base_url` and `get_host_url` prefer it over the request headers,
   so the QR URL the phone is told to open and the Google OAuth redirect URI are no longer
   derived from a client-controlled `Host` header.
4. **Bind `GET /api/auth/qr/{id}/finalize` to the waiting device.**
   It is unauthenticated and keyed only on the `qr_id`. A per-session secret issued at create time
   would close it. **Still open.**
5. **Rate-limit the QR endpoints and cap concurrent SSE connections.**
   `GET /api/auth/qr/{id}/wait` spawns a task plus a PostgreSQL query every 3 seconds per
   connection, with no auth and no cap, on a publicly reachable endpoint. **Still open.**
6. **Drop the plaintext `code` column** from `device_pair_sessions`; only `code_hash` is needed for
   lookup. Needs an `ALTER` on the live table. **Still open.**
7. **Rotate and restrict the Cloudflare API token** in `E:\MediaServer\Caddyfile`. It is a live
   credential with DNS-management rights for the hostname, stored in plaintext on disk. The file is
   correctly gitignored, but the token should still be scoped and rotated.

> Full context for the QR sign-in feature and its hardening:
> [`docs/QR_SIGNIN_WALKTHROUGH.md`](QR_SIGNIN_WALKTHROUGH.md).

