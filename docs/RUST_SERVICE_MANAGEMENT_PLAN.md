# Implementation Plan: Rust Windows Service (`MediaServerRust`) & Restart Tooling

**Status:** Proposed — Awaiting User Approval  
**Target Service:** `MediaServerRust` (Port 8001) alongside Flask `MediaServer` (Port 8000)  
**Tooling:** NSSM (Non-Sucking Service Manager) + Batch / PowerShell Scripts  
**Date:** October 15, 2026

---

## 1. Objectives

1. **Parity with Flask Service Management:** Provide a seamless one-click `scripts/restart_rust_service.bat` matching `scripts/restart_service.bat` for fast development and reloads.
2. **Persistent Windows Service (`MediaServerRust`):** Register the compiled Rust Axum binary (`media-server-api.exe`) as an automatic Windows Service via NSSM that survives reboots, runs in the background without user login, and automatically restarts on unexpected exits with log rotation.
3. **Dual-Mode Restart Logic:** Enable `scripts/restart_rust_service.bat` to work intelligently:
   - **Service Mode:** When `MediaServerRust` service is installed, stop the service, optionally recompile the latest code via `scripts\cargo.bat build --release`, restart the service, and verify health.
   - **Standalone/Dev Mode:** When not running as a Windows service, stop any existing PID on port 8001, recompile, launch the executable, and verify health.
4. **Unified Health Check Diagnostics:** Update `scripts/service_status.ps1` and add `scripts/rust_service_status.ps1` to report the status of `MediaServer`, `MediaServerRust`, and `Cloudflared` in a single view.

---

## 2. Architecture & Service Specifications

| Setting | Value |
| :--- | :--- |
| **Service Name** | `MediaServerRust` |
| **Display Name** | `Media Server API (Rust/Axum)` |
| **Description** | `Self-hosted personal media streaming server backend running Rust Axum on port 8001` |
| **Startup Type** | `SERVICE_AUTO_START` (Automatic at Windows boot) |
| **Binary Path** | `E:\MediaServer\rust\target\release\media-server-api.exe` (fallback `debug`) |
| **App Directory** | `E:\MediaServer` |
| **StdOut Log** | `E:\MediaServer\logs\rust_api.log` |
| **StdErr Log** | `E:\MediaServer\logs\rust_api_error.log` |
| **Log Rotation** | Rotate when file exceeds 10 MB (`10485760` bytes) or daily (`86400` seconds) |
| **Restart Delay** | 5000 ms on crash / unexpected termination |
| **Environment Variables** | `PATH=C:\Users\anis7\AppData\Local\Microsoft\WinGet\Links;C:\Python314\Scripts;C:\Python314;E:\postgres\pgsql\bin;%PATH%`<br>`MEDIA_SERVER_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/media_server`<br>`RUST_PORT=8001`<br>`MEDIA_SERVER_MEDIA_ROOT=D:\Flicks`<br>`MEDIA_SERVER_MEDIA_ROOTS=D:\Flicks,D:\Flicks\.archive,E:\MediaServer`<br>`MEDIA_SERVER_CACHE_DIR=E:\MediaServer\cache`<br>`MEDIA_SERVER_STATIC_DIR=E:\MediaServer\web\dist`<br>`RUST_LOG=info` |

---

## 3. Files to Create & Modify

### New Scripts:
1. `scripts/install_rust_service.ps1` — PowerShell installer that checks prerequisites (PostgreSQL, NSSM), builds the release binary using `scripts\cargo.bat build --release`, registers `MediaServerRust` via NSSM with environment and log rotation, starts the service, and validates the HTTP endpoint on `http://127.0.0.1:8001/`.
2. `scripts/install_rust_service.bat` — One-click launcher with auto-UAC elevation (`Start-Process -Verb RunAs`).
3. `scripts/restart_rust_service.ps1` — Intelligent restarter:
   - Detects if `MediaServerRust` is installed.
   - If installed: stops service, compiles latest code (if `--rebuild` or default), starts service.
   - If not installed: kills port 8001 process, compiles, starts background process.
   - Performs HTTP probes against `http://127.0.0.1:8001/` (SPA index) and `http://127.0.0.1:8001/api/movies` (Postgres query).
4. `scripts/restart_rust_service.bat` — One-click launcher for `restart_rust_service.ps1` with auto-UAC elevation.
5. `scripts/uninstall_rust_service.ps1` & `scripts/uninstall_rust_service.bat` — Clean uninstaller stopping and removing `MediaServerRust` via NSSM.
6. `scripts/rust_service_status.ps1` — Quick status check displaying service status, PID, memory usage, HTTP responses, and recent log tail.

### Modified Files:
1. `scripts/service_status.ps1` — Add `MediaServerRust` and port 8001 check to the general health check report.
2. `docs/WINDOWS_SETUP.md` & `docs/PROJECT_STATUS.md` — Document `MediaServerRust` service parameters, ports, and operational procedures.

---

## 4. Step-by-Step Implementation Sequence

```mermaid
graph TD
    A["User Approval Gate"] --> B["Build Release Binary via scripts cargo.bat"]
    B --> C["Write install_rust_service.ps1 & .bat"]
    C --> D["Write restart_rust_service.ps1 & .bat"]
    D --> E["Write uninstall_rust_service.ps1 & .bat"]
    E --> F["Write rust_service_status.ps1 & update service_status.ps1"]
    F --> G["Execute install_rust_service.bat (Register Service)"]
    G --> H["Verify Service Status & HTTP Probes (Port 8001)"]
    H --> I["Test restart_rust_service.bat"]
    I --> J["Create Completion Walkthrough Document"]
```

1. **Build Release Binary:** Execute `.\scripts\cargo.bat build --release` to ensure an optimized production executable exists at `E:\MediaServer\rust\target\release\media-server-api.exe`.
2. **Draft Installer & Uninstaller Scripts:** Implement NSSM service registration with identical resilience policies as Flask (crash auto-restart, 10MB log rotation).
3. **Draft Restart & Status Scripts:** Implement safe stop -> build -> start -> probe workflow.
4. **Update General Diagnostics:** Ensure `service_status.ps1` surveys all 3 services (`MediaServer`, `MediaServerRust`, `Cloudflared`).
5. **Execution & Live Verification:**
   - Run installation and verify `MediaServerRust` is `Running` in Windows Service Control Manager.
   - Probe `http://127.0.0.1:8001/` (status 200).
   - Probe `http://127.0.0.1:8001/api/movies` (status 200 with movie JSON).
   - Test `scripts/restart_rust_service.bat` execution.
6. **Documentation & Walkthrough:** Update `docs/WINDOWS_SETUP.md` and deliver full walkthrough in chat.

---

## 5. Verification & Safety Checks

- **Port Isolation:** Rust on `:8001` and Flask on `:8000` must run simultaneously without port conflict.
- **File Locking Safety:** Service must be stopped before recompiling the binary to avoid Windows `[WinError 32]` executable lock.
- **Database Dependency:** If PostgreSQL on port 5432 is not running, the installer/restarter must notify and start it via `scripts/start_postgres.bat`.
- **Zero-Interruption to Flask:** Flask (`MediaServer` on port 8000) and Cloudflare tunnel (`media.anisparvez.in`) must remain completely undisturbed.
