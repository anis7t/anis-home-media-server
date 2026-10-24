# SQLTools PostgreSQL Connection Configuration Walkthrough

## Summary of Changes

We configured the workspace settings and extension recommendations in Antigravity IDE / VS Code for the SQLTools extension (`mtxr.sqltools` + `mtxr.sqltools-driver-pg`) to connect to our local PostgreSQL database instances.

---

## Deliverables & Modified Files

### 1. Workspace Configuration ([`.vscode/settings.json`](file:///e:/MediaServer/.vscode/settings.json))
Added the `sqltools.connections` configuration block specifying two database profiles:

1. **`Media Server (PostgreSQL)`** (Primary Production Database):
   - **Driver**: `PostgreSQL`
   - **Server / Host**: `127.0.0.1`
   - **Port**: `5432`
   - **Database**: `media_server`
   - **Username**: `postgres`
   - **Password**: `postgres`
   - **Connection Timeout**: `15` seconds
   - **Preview Limit**: `50` rows

2. **`Media Server Integration Test (PostgreSQL)`** (Integration Test Database):
   - **Driver**: `PostgreSQL`
   - **Server / Host**: `127.0.0.1`
   - **Port**: `5432`
   - **Database**: `media_integration_test`
   - **Username**: `postgres`
   - **Password**: `postgres`
   - **Connection Timeout**: `15` seconds
   - **Preview Limit**: `50` rows

### 2. Extension Recommendations ([`.vscode/extensions.json`](file:///e:/MediaServer/.vscode/extensions.json))
Added the extension identifiers to workspace recommendations:
- `"mtxr.sqltools"` — SQLTools database management tool.
- `"mtxr.sqltools-driver-pg"` — PostgreSQL / CockroachDB official driver for SQLTools.

---

## Verification Results

### 1. JSON Configuration Validation
Executed automated parsing of [`.vscode/settings.json`](file:///e:/MediaServer/.vscode/settings.json) and [`.vscode/extensions.json`](file:///e:/MediaServer/.vscode/extensions.json):
```text
Settings valid JSON: OK
Extensions valid JSON: OK
SQLTools connections: 2 profiles loaded successfully
Recommendations: 8 extensions registered
```

### 2. Database Reachability & Credential Verification
Verified network socket authentication and catalog query against PostgreSQL on `127.0.0.1:5432`:
```text
Database media_server: connected successfully, 12 public tables (movies, sessions, transcode_jobs, progress, users, devices, settings, etc.)
Database media_integration_test: connected successfully, 0 public tables
```

---

## How to Use in the IDE

1. Open the **SQLTools** activity bar icon (database icon on the left sidebar) in Antigravity IDE / VS Code.
2. Under **CONNECTIONS**, you will see:
   - `Media Server (PostgreSQL)`
   - `Media Server Integration Test (PostgreSQL)`
3. Click the connect plug icon next to **`Media Server (PostgreSQL)`**.
4. You can now explore tables, inspect columns, run interactive queries, and view table data directly within the IDE.
