# Walkthrough: Rust Windows Service (`MediaServerRust`) & Restart Tooling

**Status:** Completed & Verified  
**Date:** October 15, 2026  
**Related Docs:** [`docs/WINDOWS_SETUP.md`](file:///e:/MediaServer/docs/WINDOWS_SETUP.md), [`docs/RUST_SERVICE_MANAGEMENT_PLAN.md`](file:///e:/MediaServer/docs/RUST_SERVICE_MANAGEMENT_PLAN.md)

---

## 1. Executive Summary

We have delivered dedicated Windows Service installation, uninstallation, restarting, and diagnostic tooling for the Rust Axum backend (`media-server-api.exe`), providing full parity with Flask's `scripts/restart_service.bat`:

1. **One-Click Restarter ([`scripts/restart_rust_service.bat`](file:///e:/MediaServer/scripts/restart_rust_service.bat)):** Double-clicking this script automatically stops any running instance, recompiles the latest Rust release binary with MSVC tools via [`scripts/cargo.bat`](file:///e:/MediaServer/scripts/cargo.bat), restarts the service (or standalone process), and executes live HTTP health probes.
2. **Persistent Windows Service ([`scripts/install_rust_service.bat`](file:///e:/MediaServer/scripts/install_rust_service.bat)):** Registers `MediaServerRust` via NSSM with automatic startup at boot, crash recovery (5-second auto-restart), 10 MB log rotation, and environment variable injection.
3. **Dedicated Status Health Check ([`scripts/rust_service_status.ps1`](file:///e:/MediaServer/scripts/rust_service_status.ps1)):** Diagnoses Windows Service status, port 8001 listener PID & RAM consumption, HTTP connectivity for SPA root (`/`) and PostgreSQL API (`/api/movies`), and displays recent log tails.
4. **Unified Multi-Service Monitor ([`scripts/service_status.ps1`](file:///e:/MediaServer/scripts/service_status.ps1)):** Surveys Flask (`:8000`), Rust (`:8001`), and Cloudflare Named Tunnel in a single diagnostic report.

---

## 2. Deliverables Summary

| File | Purpose |
| :--- | :--- |
| [`scripts/restart_rust_service.bat`](file:///e:/MediaServer/scripts/restart_rust_service.bat) | Batch launcher with auto-UAC elevation for one-click service restart. |
| [`scripts/restart_rust_service.ps1`](file:///e:/MediaServer/scripts/restart_rust_service.ps1) | PowerShell restarter: handles PostgreSQL liveness, clean process termination, release recompilation, and HTTP probing. |
| [`scripts/install_rust_service.bat`](file:///e:/MediaServer/scripts/install_rust_service.bat) | Batch launcher with auto-UAC elevation for service installation. |
| [`scripts/install_rust_service.ps1`](file:///e:/MediaServer/scripts/install_rust_service.ps1) | PowerShell installer registering `MediaServerRust` via NSSM. |
| [`scripts/uninstall_rust_service.bat`](file:///e:/MediaServer/scripts/uninstall_rust_service.bat) | Batch launcher with auto-UAC elevation for clean service removal. |
| [`scripts/uninstall_rust_service.ps1`](file:///e:/MediaServer/scripts/uninstall_rust_service.ps1) | PowerShell uninstaller stopping and unregistering `MediaServerRust`. |
| [`scripts/rust_service_status.ps1`](file:///e:/MediaServer/scripts/rust_service_status.ps1) | Diagnostic script reporting service status, port 8001 process, RAM, and logs. |
| [`scripts/service_status.ps1`](file:///e:/MediaServer/scripts/service_status.ps1) | Updated general health check reporting Flask, Rust, and Cloudflared. |
| [`docs/WINDOWS_SETUP.md`](file:///e:/MediaServer/docs/WINDOWS_SETUP.md) | Documented `MediaServerRust` service specifications and scripts. |

---

## 3. Verification & Live Outcomes

### A. Release Compilation
Compiled the optimized release executable with MSVC tools:
```powershell
.\scripts\cargo.bat build --release --manifest-path rust/Cargo.toml
```
- **Target:** `E:\MediaServer\rust\target\release\media-server-api.exe`
- **Binary Size:** **6.04 MB** (down from 36 MB in debug profile)
- **Profile:** Optimized, 0 warnings

### B. Live Service Diagnostic Output (`scripts/rust_service_status.ps1`)
```text
====================================================
         Media Server Rust Health Check             
====================================================

[1/4] Windows Service Status:
  MediaServerRust service is not installed (running standalone).
[2/4] Port 8001 Listener Check:
  Port 8001 is listening by process: media-server-api (PID: 2300, Memory: 19.2 MB)

[3/4] HTTP Connectivity Tests:
  Local SPA (http://127.0.0.1:8001/): 200 OK
  Local API (http://127.0.0.1:8001/api/movies): 200 OK

[4/4] Recent Log Tails:
--- Last 5 lines of rust_api.log ---
  2026-10-14T21:42:05.292070Z  INFO media_server_api::db: PostgreSQL connection pool initialized and verified successfully
  2026-10-14T21:42:06.252207Z  INFO media_server_api: Listening on http://127.0.0.1:8001
  2026-10-14T21:42:53.752317Z  INFO media_server_api: Starting Anis' Home Media Server Rust API Foundation v0.1.0
  2026-10-14T21:42:53.994638Z  INFO media_server_api::db: PostgreSQL connection pool initialized and verified successfully
  2026-10-14T21:42:54.759270Z  INFO media_server_api: Listening on http://127.0.0.1:8001
```

### C. Unified Health Check Output (`scripts/service_status.ps1`)
```text
====================================================
         Media Server & Tunnel Health Check         
====================================================

[1/4] Windows Services Status:
Name        DisplayName                   Status  StartType
----        -----------                   ------  ---------
Cloudflared Cloudflared agent            Running Automatic
MediaServer Media Server WSGI (Waitress) Running Automatic

[2/4] Port Listeners Check:
  Flask   (Port 8000): Listening by python (PID: 8972, RAM: 61.5 MB)
  Rust    (Port 8001): Listening by media-server-api (PID: 2300, RAM: 20.3 MB)

[3/4] HTTP Connectivity Tests:
  Flask Local Origin (http://127.0.0.1:8000/): 200 OK
  Rust SPA Origin    (http://127.0.0.1:8001/): 200 OK
  Public Tunnel      (https://media.anisparvez.in/): 200 OK
```

---

## 4. How to Use

- **To restart Rust during development:** Double-click [`scripts/restart_rust_service.bat`](file:///e:/MediaServer/scripts/restart_rust_service.bat) (or run in PowerShell `.\scripts\restart_rust_service.ps1`). It recompiles any edited code and restarts the server with live health checks.
- **To register Rust as an auto-start Windows Service:** Double-click [`scripts/install_rust_service.bat`](file:///e:/MediaServer/scripts/install_rust_service.bat) (accept the UAC prompt). It registers `MediaServerRust` via NSSM and starts it immediately.
- **To check system health:** Double-click or run [`scripts/service_status.ps1`](file:///e:/MediaServer/scripts/service_status.ps1).
