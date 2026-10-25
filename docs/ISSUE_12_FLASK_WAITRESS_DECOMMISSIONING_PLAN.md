# Implementation Plan — Issue 12: Flask/Waitress Era Decommissioning Loose Ends

- **Date:** 2026-10-24
- **Author:** Antigravity (Advanced Agentic Pair Programmer)
- **Status:** 📋 **PENDING USER APPROVAL**
- **Target Tracking:** [`docs/Current issues.md`](Current%20issues.md) (Issue 12), [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md)

---

## 1. Context & Motivation

Following the full migration to native Rust/Axum (`MediaServerRust`), React 19 SPA (`web/dist`), and PostgreSQL 18.4 (`MediaServerPG`), three operational and configuration loose ends from the legacy Flask/Waitress/SQLite era remain:

1. **`MediaServer` Windows Service registration:** The Stopped/Manual NSSM service `MediaServer` is still registered in Windows Service Control Manager, pointing to `E:\MediaServer\venv\Scripts\python.exe E:\MediaServer\run_production.py` (which no longer exists).
2. **`media-db` MCP server:** Currently configured in `C:\Users\anis7\.gemini\config\mcp_config.json` and `opencode.json` using `uvx fastmcp-sqlite` pointing to `.opencode/db/media.snapshot.db` (retired SQLite snapshot). It serves stale pre-migration rows to AI agents.
3. **Stale external duplicate directory:** `C:\Users\anis7\Documents\Anis-Media-Server-Intro\` (294 MB) was the external staging folder used before intro assets were brought in-tree under `docs/opening-sequence/`.
4. **Vite proxy configuration:** Marked as open in Issue 12 table, though already unified in Phase 11 Slice 11.6 on `SERVER_ORIGIN = http://127.0.0.1:8000`. Needs formal verification and documentation closure.

---

## 2. Scope

### In Scope
- **Windows Service Cleanup:** Deregister the legacy `MediaServer` service via NSSM (`C:\MediaServer\bin\nssm.exe remove MediaServer confirm`).
- **MCP Database Alignment:** 
  - Retire the stale SQLite `media-db` entry in `C:\Users\anis7\.gemini\config\mcp_config.json` and `opencode.json`.
  - Configure `postgresql-mcp` (or native PostgreSQL database access) pointing to the authoritative `media_server` database on port 5432 so agents query live production data.
  - Archive/remove the stale `.opencode/db/media.snapshot.db` SQLite snapshot.
- **External Folder Hygiene:** Verify zero remaining repository references and delete the duplicate folder `C:\Users\anis7\Documents\Anis-Media-Server-Intro\`.
- **Vite Proxy Verification:** Run `npm run test` and `npm run typecheck` in `web/` to verify proxy and build health.
- **Documentation Updates:** Update [`docs/Current issues.md`](Current%20issues.md) and [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md) marking all Issue 12 items as resolved.

### Out of Scope
- Modifying production Rust backend logic, routes, or database schemas.
- Modifying running production services `MediaServerRust`, `MediaServerCaddy`, or `MediaServerPG`.
- Touching Flutter client code or Android assets.

---

## 3. Detailed Implementation Steps

### Step 1: Remove Legacy `MediaServer` NSSM Service
1. Confirm service status: `Get-Service -Name MediaServer` (must be Stopped).
2. Execute deregistration:
   ```powershell
   & "C:\MediaServer\bin\nssm.exe" remove MediaServer confirm
   ```
3. Verify that `Get-Service -Name MediaServer` returns non-existent, while `MediaServerRust`, `MediaServerCaddy`, and `MediaServerPG` remain intact and Running.

### Step 2: Reconfigure MCP Database Tools & Purge SQLite Snapshot
1. In `C:\Users\anis7\.gemini\config\mcp_config.json`:
   - Replace the `fastmcp-sqlite` `media-db` server with `postgresql-mcp` (or configure `postgres` pointing to `POSTGRES_DB: "media_server"` on `127.0.0.1:5432`).
2. In `opencode.json`:
   - Remove `media-db` referencing `fastmcp-sqlite` and update `postgres` to target `media_server` instead of `media_dev`.
3. In `.opencode/db/`:
   - Remove or archive the stale `.opencode/db/media.snapshot.db`.

### Step 3: Remove Stale External Intro Directory
1. Verify no active code in the repository references `C:\Users\anis7\Documents\Anis-Media-Server-Intro\`.
2. Remove `C:\Users\anis7\Documents\Anis-Media-Server-Intro\` and reclaim 294 MB of disk space.

### Step 4: Verify Web Dev Proxy & Build
1. In `web/`:
   - Run `npm run typecheck`.
   - Run `npm run test` (all 318+ tests must pass).
   - Confirm `web/vite.config.ts` cleanly proxies all server prefixes to `http://127.0.0.1:8000`.

### Step 5: Update Documentation & Resolution Logs
1. In [`docs/Current issues.md`](Current%20issues.md):
   - Update Issue 12 table items 3, 4, and 5 to ✅ **Fixed**, noting the exact cleanup actions.
   - Update the Issue 12 summary text.
2. In [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md):
   - Update Category 3 (Decommissioning & System Hygiene) in the Active Open Items register to marked as resolved.

---

## 4. Exit Criteria

- [ ] `Get-Service -Name MediaServer` confirms the legacy Waitress service is completely unregistered.
- [ ] `MediaServerRust`, `MediaServerCaddy`, and `MediaServerPG` are running healthy on ports 8000, 443/80, and 5432.
- [ ] No MCP configuration points to the retired SQLite snapshot `.opencode/db/media.snapshot.db`.
- [ ] `C:\Users\anis7\Documents\Anis-Media-Server-Intro\` is removed.
- [ ] `web/` tests and typecheck pass with zero failures.
- [ ] `docs/Current issues.md` and `docs/PROJECT_STATUS.md` reflect Issue 12 as fully closed.

---

## 5. Risks & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Accidental removal of active service | Server outage | Explicitly target service name `MediaServer`; never touch `MediaServerRust`, `MediaServerCaddy`, or `MediaServerPG`. |
| Loss of historical intro files | Data loss | All assets, frames, scripts, and golden JSON already exist in-tree under `docs/opening-sequence/` and are committed to Git. |
| MCP tool syntax error | IDE tool crash | Validate JSON syntax in `mcp_config.json` and `opencode.json` prior to saving. |

---

## 6. Open Decisions for User

1. **MCP Database Tool Preference:**
   - **Option A (Recommended):** Reconfigure the database MCP server to connect to live PostgreSQL 18.4 (`MediaServerPG` database `media_server` on port 5432) using `postgresql-mcp`, so AI agents can query live catalog and progress data.
   - **Option B:** Simply remove/disable database MCP servers entirely and rely on native `psql` / command-line querying.
