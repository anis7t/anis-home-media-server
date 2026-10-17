# SQLTools PostgreSQL Connection Configuration Plan

## 1. Scope

### What Changes
- **Workspace Settings ([`.vscode/settings.json`](file:///e:/MediaServer/.vscode/settings.json))**:
  - Add the `sqltools.connections` configuration block specifying the active PostgreSQL server connection:
    - **Name**: `Media Server (PostgreSQL)`
    - **Driver**: `PostgreSQL`
    - **Host / Server**: `127.0.0.1`
    - **Port**: `5432`
    - **Database**: `media_server`
    - **Username**: `postgres`
    - **Password**: `postgres`
    - **Connection Timeout**: `15` seconds
    - **Preview Limit**: `50` rows
  - Add an optional secondary test profile `Media Server Integration Test (PostgreSQL)` pointing to `media_integration_test` on `127.0.0.1:5432` for seamless switching during integration test inspection.
- **Workspace Recommended Extensions ([`.vscode/extensions.json`](file:///e:/MediaServer/.vscode/extensions.json))**:
  - Add `"mtxr.sqltools"` and `"mtxr.sqltools-driver-pg"` to `recommendations` so the workspace declares the exact extensions powering this configuration.

### What Deliberately Does Not Change
- No changes to PostgreSQL server settings, databases, roles, or database schemas.
- No changes to Rust (`rust/src/config.rs`) or Python application source code.
- No changes to existing `.vscode/settings.json` formatters, linter rules, or terminal profiles.

---

## 2. Exit Criteria

- [ ] [`.vscode/settings.json`](file:///e:/MediaServer/.vscode/settings.json) parses as valid JSON with the `sqltools.connections` configuration correctly formatted and schema-compliant.
- [ ] [`.vscode/extensions.json`](file:///e:/MediaServer/.vscode/extensions.json) lists `"mtxr.sqltools"` and `"mtxr.sqltools-driver-pg"` in `recommendations`.
- [ ] Direct validation confirms the connection parameters (`127.0.0.1:5432`, `postgres`, `media_server`) authenticate successfully and read schema tables (`movies`, `users`, `sessions`, `transcode_jobs`, etc.).
- [ ] The SQLTools extension can discover and load the connection definition from the workspace configuration.

---

## 3. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **JSON syntax error in `.vscode/settings.json`** | Breaks editor workspace settings or language formatting | Validate JSON structure programmatically before and after editing. |
| **Plaintext password exposure in Git** | Accidental commit of credentials | The credentials (`postgres:postgres` on `127.0.0.1`) are local dev defaults already documented across scripts and test files in the repository. SQLTools also supports `"askForPassword": false` with explicit password for local convenience. |
| **Driver mismatch** | SQLTools fails to activate PostgreSQL driver | Ensure driver name matches the installed `mtxr.sqltools-driver-pg` identifier (`"driver": "PostgreSQL"`). |

---

## 4. Open Decisions

1. **Include Test Database**: Should we include the `media_integration_test` connection alongside `media_server` in `sqltools.connections` for instant switching? (Default: Include both with `media_server` listed first).
2. **Password Storage**: Keep `password: "postgres"` configured for immediate one-click connection without prompts, or prompt via `"askForPassword": true`? (Recommended: plaintext password for local development container/instance).

---

## 5. Execution Steps

1. **Update `.vscode/extensions.json`**:
   - Add `"mtxr.sqltools"` and `"mtxr.sqltools-driver-pg"`.
2. **Update `.vscode/settings.json`**:
   - Append `"sqltools.connections"` array with the `media_server` (and `media_integration_test`) definitions.
3. **Verification**:
   - Validate JSON syntax.
   - Verify connection against PostgreSQL on `127.0.0.1:5432`.
