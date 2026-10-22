# Phase C5 Slice 2 — Device Management Parity (`GET /api/devices`, `/api/devices/rename`, `/api/devices/delete`) Implementation Plan

**Date:** 2026-10-16  
**Target Branch:** `feat/rust-transcode-worker`  
**Prerequisites:** Phase C5 Slice 1 complete & committed (`68538e1`)  
**Objective:** Port the remaining device management endpoints natively to Rust Axum, eliminate the `/api/devices/*` reverse-proxy bridge group from `rust/src/lib.rs`, enforce fail-closed admin authorization semantics, and ensure 100% contract parity with the Flutter client and React SPA.

> **Superseded in part (2026-10-23, access-control Phase 2).** The 403 rule described below ("you can
> only rename/remove your current device") now reads "your current device **or one you own**", and
> `GET /api/devices` is scoped per user. The authoritative description is the *Device ownership &
> watch-history scoping* section of `AGENTS.md`.

---

## 1. Background & Current State

In Phase C3a, device registration (`DeviceService::register_device`), heartbeat keepalive (`POST /api/devices/heartbeat`), and Client Hints ingestion (`POST /api/devices/client-hints`) were ported natively to Rust Axum (`rust/src/routes/devices.rs`, `rust/src/services/device_service.rs`).

However, the fleet viewing and mutation endpoints were temporarily deferred to Phase C3b because of their authorization dependencies:
- `GET /api/devices`
- `POST /api/devices/rename`
- `POST /api/devices/delete`

Currently, in `rust/src/lib.rs`, these three endpoints are forwarded to Flask `:8000` via the reverse-proxy bridge:
```rust
.route("/api/devices", axum::routing::any(routes::proxy::proxy_handler))
.route("/api/devices/rename", axum::routing::any(routes::proxy::proxy_handler))
.route("/api/devices/delete", axum::routing::any(routes::proxy::proxy_handler))
```

This represents one of the 5 remaining reverse-proxy groups in `lib.rs`. Porting these natively will completely eliminate `/api/devices/*` from the proxy bridge, reducing the remaining bridge groups from 5 to 4 (`/auth/*`, `/api/auth/*`, `/api/admin/*`, `/api/storage/*`).

---

## 2. Technical Specifications & Contract Matching

### 2.1 Shared Admin Authorization
- Reuse fail-closed admin PIN resolution from the database `settings` table (`SELECT value FROM settings WHERE key = 'admin_pin'`).
- If `admin_pin` is unset or empty, no PIN is accepted (`has_pin = false`).
- PIN accepted strictly via `X-Admin-Pin` header or JSON body `admin_pin` (never from query parameters).
- Create a reusable `AuthService::is_admin_authorized` helper so both `ScanService` and `DeviceService` (and upcoming storage/admin services) share a single hardened authorization logic.

### 2.2 `GET /api/devices` Handler
1. **Device Identification**:
   - Extract caller's `current_device_id` using the identical resolution rule from C3a (`resolve_device_id`: cookie `ms_device_id` -> header `X-Device-Id` -> sha256(`ip|ua`)).
   - Touch/record caller request facts to ensure the calling device is registered and updated.
2. **Querying Database**:
   - Select all devices from `devices` ordered by `last_seen DESC`.
   - Select watch history from `device_watch_history h LEFT JOIN movies m ON h.filename = m.filename` ordered by `h.last_watched DESC`.
3. **Data Transformation & Formatting**:
   - Activity check: `is_active = (now - last_seen) <= 180 seconds`.
   - Watch history formatting: format duration and position strings (`M:SS` or `H:MM:SS`), completion percentage, and poster URL resolution (`/tmdb-poster/{tmdb_id}` or local `/poster/{filename}`).
   - Icon classification: `📱` Mobile, `📟` Tablet, `📺` Smart TV, `🎮` Console, `🤖` Tool/Bot, `💻` Desktop.
4. **Authorization Filtering**:
   - If **admin authorized**: return all devices and fleet-wide stats.
   - If **not admin authorized**: filter `devices` list to only the caller's device (`d.device_id == current_device_id`), and compute summary statistics solely over the filtered list.
5. **Response Shape**:
   ```json
   {
     "devices": [ ... ],
     "stats": {
       "total_devices": 1,
       "active_now": 1,
       "offline_count": 0,
       "cloudflare_count": 0,
       "lan_count": 1,
       "localhost_count": 0
     },
     "current_device_id": "dev_..."
   }
   ```

### 2.3 `POST /api/devices/rename` Handler
1. **Request Body**:
   - Accepts JSON `{"device_id": string, "name": string}`.
   - If `device_id` is missing or empty: return HTTP 400 `{"error": "device_id is required"}`.
2. **Authorization Gate**:
   - If caller is **not admin** and `device_id != current_device_id`:
     Return HTTP 403 `{"error": "Unauthorized: You can only rename your current device."}`.
3. **Execution**:
   - Update `devices SET custom_name = $1 WHERE device_id = $2`. (Empty trimmed string is converted to `NULL`).
   - Return HTTP 200 `{"success": true}`.

### 2.4 `POST /api/devices/delete` Handler
1. **Request Body**:
   - Accepts JSON `{"device_id": string}`.
   - If `device_id` is missing or empty: return HTTP 400 `{"error": "device_id is required"}`.
2. **Authorization Gate**:
   - If caller is **not admin** and `device_id != current_device_id`:
     Return HTTP 403 `{"error": "Unauthorized: You can only remove your current device."}`.
3. **Execution**:
   - Delete from `device_watch_history WHERE device_id = $1`.
   - Delete from `devices WHERE device_id = $1`.
   - If `ms_device_id` cookie matches the deleted `device_id`, add response header `Set-Cookie: ms_device_id=; Max-Age=0; Path=/; SameSite=Lax`.
   - Return HTTP 200 `{"success": true}`.

---

## 3. Scope

### In Scope for Slice 2
- **`rust/src/services/auth_service.rs`**: Reusable admin PIN verification helper (`is_admin_authorized`).
- **`rust/src/services/device_service.rs`**: Add `get_all_devices`, `rename_device`, `delete_device` queries and formatting methods to `DeviceService`.
- **`rust/src/routes/devices.rs`**: Implement `list_devices_handler`, `rename_device_handler`, and `delete_device_handler`.
- **`rust/src/lib.rs`**:
  - Mount new routes under `devices_routes`.
  - Delete `/api/devices`, `/api/devices/rename`, `/api/devices/delete` from `proxy_routes`.
- **`rust/tests/devices_test.rs`**: Add integration tests verifying:
  - `GET /api/devices` unauthenticated returns only current device; with admin PIN returns full fleet.
  - `POST /api/devices/rename` self-rename succeeds; renaming other device returns 403; admin renaming any device succeeds; missing ID returns 400.
  - `POST /api/devices/delete` self-delete succeeds and unsets cookie; deleting other device returns 403; admin delete succeeds; missing ID returns 400.
- Verify full test battery (`cargo test`) and run probe (`scripts/probe_android_api.py`).

### Deliberately Out of Scope
- `/api/storage/*` (Storage retention and orphan cache purge - deferred to Slice 3).
- `/auth/*`, `/api/auth/*`, and `/api/admin/*` (Session tokens & Google OAuth - deferred to Slice 4).
- Production port swap (`:8001` -> `:8000`).

---

## 4. Exit Criteria

1. **Native Parity**:
   - `GET /api/devices` returns HTTP 200 with JSON matching exact Flask schema (`devices`, `stats`, `current_device_id`).
   - `POST /api/devices/rename` correctly updates `custom_name` in PostgreSQL.
   - `POST /api/devices/delete` cascades deletion across `devices` and `device_watch_history`.
2. **Security & Authorization Invariants**:
   - Non-admin callers see only their own device and cannot rename/delete other devices (HTTP 403).
   - Admin callers (via `X-Admin-Pin`) can view all devices and mutate any device.
   - Empty or unset `admin_pin` in settings fails closed.
   - PIN is never accepted via URL query parameter.
3. **Proxy Group Elimination**:
   - Zero `/api/devices/*` routes remain in `proxy_routes` in `rust/src/lib.rs`.
   - Remaining proxy groups reduced from 5 to 4.
4. **Automated Verification**:
   - All tests in `rust/tests/devices_test.rs` pass.
   - Repository-wide test suite passes with 0 failures (235+ tests).
   - `scripts/probe_android_api.py` passes 22/22 on both `:8000` and `:8001`.

---

## 5. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| **Device ID Divergence** | The `get_or_create_device_id` function in Rust C3a was already validated against Flask byte-for-byte. `current_device_id` uses the exact same resolution. |
| **Non-Admin Information Leak** | Filter `devices` array to `[d for d in devices if d.is_current]` BEFORE returning if `!is_admin_authorized`. Recompute all summary counters (`stats`) over the filtered slice. |
| **Cookie Deletion on Windows Browsers** | Emit standard `Set-Cookie: ms_device_id=; Max-Age=0; Path=/; SameSite=Lax` when the deleted ID matches the request cookie. |
| **Test Database Pollution** | Use `TEST_PREFIX = "dev_rustc3a_"` and explicit teardown query `DELETE FROM devices WHERE device_id LIKE 'dev_rustc3a_%'` guarded by `SERIAL` mutex in `devices_test.rs`. |

---

## 6. Open Decisions for User Confirmation

1. **Admin Authorization Porting Strategy**:
   - Should we extract the `is_admin_authorized` PIN validator into a dedicated `AuthService` module (`rust/src/services/auth_service.rs`) so it can be shared cleanly across `devices`, `scan`, `storage`, and `admin` routes? *(Recommended: Yes)*
2. **Device Deletion Cascade**:
   - Deleting a device removes rows from `device_watch_history` and `devices`. Should this continue to be atomic via a single database transaction? *(Recommended: Yes, wrap in `sqlx::Transaction`)*
