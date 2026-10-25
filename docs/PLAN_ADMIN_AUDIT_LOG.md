# Implementation Plan — Dedicated Admin Mutation Audit Log Table in PostgreSQL (Category 5.2)

## 1. Executive Summary & Objective

- **Context:** Currently, security-sensitive administrative mutations (Admin PIN rotation, device renames/deletions, allowlist modifications, storage cache purges, and media deletions) are logged only as ephemeral lines to `logs/rust_api.log`. Log rotation and service restarts make historical auditing difficult, and there is no queryable audit trail in PostgreSQL or administrative UI.
- **Objective:** Create a dedicated, indexed `audit_logs` table in PostgreSQL 18.4, implement an asynchronous non-blocking `AuditService` in Rust Axum, instrument all administrative mutation routes, expose an admin-protected `GET /api/admin/audit-logs` query endpoint, and prove durability and isolation via automated integration tests.

---

## 2. Proposed Changes & Architecture

### A. Database Schema (`rust/src/db.rs`)
1. **Create Table `audit_logs`:**
   ```sql
   CREATE TABLE IF NOT EXISTS audit_logs (
       id          BIGSERIAL PRIMARY KEY,
       actor_type  TEXT NOT NULL,        -- 'admin_session', 'admin_pin', 'user_session', 'system'
       actor_id    TEXT NOT NULL,        -- email, user_id, or 'pin'
       action      TEXT NOT NULL,        -- 'pin_change', 'device_rename', 'device_delete', 'allowlist_update', 'cache_purge', 'media_delete'
       target_type TEXT,                 -- 'device', 'user', 'settings', 'cache', 'media'
       target_id   TEXT,                 -- device_id, email, filename, etc.
       details     JSONB,                -- structured metadata (old/new names, IP, user-agent, result counts)
       ip_address  TEXT,
       created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
   );

   CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at
       ON audit_logs (created_at DESC);
   CREATE INDEX IF NOT EXISTS idx_audit_logs_action
       ON audit_logs (action);
   CREATE INDEX IF NOT EXISTS idx_audit_logs_actor
       ON audit_logs (actor_type, actor_id);
   ```

### B. Audit Service (`rust/src/services/audit_service.rs` & `rust/src/models/audit.rs`)
1. **Audit Models:**
   - Define `AuditLogEntry` and `AuditLogResponse` models with `serde::Serialize` and `serde::Deserialize`.
2. **AuditService Implementation:**
   - `record_event(pool, actor_type, actor_id, action, target_type, target_id, details, ip_address)`:
     - Asynchronous, fire-and-forget or awaited with error containment (`if let Err(e) = ... tracing::error!(...)`).
     - Logging failure must never fail the primary administrative request.
   - `list_logs(pool, limit, offset, action_filter)`:
     - Queries `audit_logs` ordered by `created_at DESC` with pagination and optional action filtering.
     - Returns `{ "logs": Vec<AuditLogEntry>, "total": i64 }`.

### C. Route Instrumentation & Admin Endpoint
1. **Admin Query Route (`GET /api/admin/audit-logs`):**
   - Registered under `/api/admin/audit-logs` in `rust/src/routes/admin.rs`.
   - Requires administrative authorization (Admin PIN or Admin Google session) via `AuthService::is_admin_authorized`.
   - Supports query parameters: `limit` (default 50, clamp 1..200), `offset` (default 0), `action` (optional string filter).
2. **Instrumentation of Administrative Mutations:**
   - **Admin PIN Rotation:** In `rust/src/routes/admin.rs` (`change_admin_pin_handler`), record `action: 'pin_change'`.
   - **Device Rename:** In `rust/src/routes/devices.rs` (`rename_device_handler`), record `action: 'device_rename'` with target device ID, previous name, and new name.
   - **Device Delete/Unlink:** In `rust/src/routes/devices.rs` (`delete_device_handler`), record `action: 'device_delete'` with target device ID.
   - **Allowlist Mutations:** In `rust/src/routes/auth.rs` (`post_allowlist_handler`), record `action: 'allowlist_update'` with the list of configured emails.
   - **Storage Cache Purge:** In `rust/src/routes/storage.rs` / `manage.rs` (`purge_orphaned_cache_handler`), record `action: 'cache_purge'`.
   - **Media Delete:** In `rust/src/routes/storage.rs` (`delete_media_handler`), record `action: 'media_delete'` with filename.

### D. Scope Boundaries (What Deliberately Does NOT Change)
- **Public & Guest Endpoints:** Regular streaming (`/media/*`, `/hls/*`, `/api/progress`) and guest browsing do not write audit records. Audit logging is strictly reserved for administrative mutations to prevent database bloat.
- **Client Contracts:** Existing API shapes for device mutations, allowlist, and storage management remain 100% backward compatible; the new endpoint is strictly additive (`GET /api/admin/audit-logs`).
- **Android / Fire TV App:** Mobile and TV clients are untouched (`probe_android_api.py` contract remains intact).

---

## 3. Exit Criteria

- [ ] **Database Schema:** `audit_logs` table and indexes are automatically created via `ensure_schema()` in `rust/src/db.rs`.
- [ ] **Integration Test Suite:** Dedicated Rust test suite (`rust/tests/audit_log_test.rs`) verifying:
  - Performing administrative actions (device rename, device delete, allowlist update, PIN change) creates corresponding structured rows in `audit_logs`.
  - Anonymous callers cannot access `GET /api/admin/audit-logs` (returns `401 Unauthorized`).
  - Authorized admins can retrieve and filter audit logs via `GET /api/admin/audit-logs`.
  - Detail payloads properly serialize IP addresses, actor identities, and metadata.
- [ ] **Full Regression Suite:** `api_contracts_test`, `user_progress_test`, and `admin_auth_test` pass with zero failures.
- [ ] **Contract Integrity:** `python scripts/probe_android_api.py` passes 22/22 endpoints.
- [ ] **Web Suite Verification:** All 46 Vitest suites in `web/` pass.
- [ ] **Production Deployment:** Release binary compiled via `scripts/cargo.bat build --release`, service restarted and verified healthy.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Database write overhead on admin actions** | Slight latency increase on administrative mutations | Indexed inserts take `< 1ms`; logging failures are wrapped and logged to tracing without causing request failure. |
| **Audit log growth over time** | Unbounded table growth in PostgreSQL | Indexed by `created_at DESC`; rows are only generated on manual administrative operations (typically <10 per week in home server setting). Future retention sweeper can archive logs older than 1 year if needed. |
| **Unauthorized access to audit history** | Leaking administrative metadata or IP addresses | Route is strictly guarded by `AuthService::is_admin_authorized`, requiring verified Google admin session or Admin PIN. |

---

## 5. Open Decisions

1. **Audit Log Read Access:**
   - **Option A (Recommended):** Admin-only access. Only callers with an active Admin Google session or valid `X-Admin-Pin` header can read `GET /api/admin/audit-logs`. Anonymous viewers receive 401 Unauthorized.
   - **Option B:** Allow viewers to inspect a redacted audit log (hiding IP addresses and sensitive details).
