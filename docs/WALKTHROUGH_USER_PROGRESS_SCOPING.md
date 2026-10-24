# Walkthrough — Per-User Playback Progress Scoping (Category 5.1)

## 1. Executive Summary

- **Component:** Playback Progress Subsystem (`progress` table, `ProgressService`, `MovieService`, Axum API routes `/api/progress`, `/api/movies`, `/api/movie/{filename}`).
- **Objective:** Scope video playback resume points by `user_id` in PostgreSQL and Rust Axum. Unify playback resume points across all devices registered to an authenticated user (laptop, phone, smart TV), eliminate progress collision between household members, provide fallback for unauthenticated guests, and maintain 100% wire-contract compatibility with web and mobile clients.
- **Status:** **✅ RESOLVED (100% Verified)**
- **Date:** 2026-10-24

---

## 2. Problem Statement & Architecture

### The Pre-Fix Limitations
1. **Global Collision:** The legacy `progress` table had `filename TEXT PRIMARY KEY`. If User A and User B watched the same movie, their positions collided and overwrote each other.
2. **Device Fragmentation:** To prevent device collisions, `device_watch_history` tracked progress per `(device_id, filename)`. However, if User A started a movie on their phone and continued on their living room TV or laptop, their positions did not sync because the devices had distinct `device_id` values.
3. **Guest Overwrites:** Unauthenticated guests watching movies on shared screens could overwrite signed-in account resume positions.

### The Solution: Option A Precedence
1. **PostgreSQL Schema Modernization:**
   - Added `user_id BIGINT REFERENCES users(id) ON DELETE CASCADE` and surrogate primary key `id BIGSERIAL PRIMARY KEY`.
   - Dropped the single-column primary key on `(filename)`.
   - Added composite constraint `CONSTRAINT uq_progress_user_filename UNIQUE NULLS NOT DISTINCT (user_id, filename)`. Using PostgreSQL's native `NULLS NOT DISTINCT`, multiple NULL `user_id` values for the same movie are treated as duplicates, ensuring exactly 1 global fallback row for guests per movie, and exactly 1 row per authenticated user.
   - Added indexes on `(user_id, updated_at DESC)` and `(filename)`.
2. **Effective Identity Resolution (`AuthService::resolve_effective_user_id`):**
   - Automatically resolves `user_id`:
     - Checks active session cookie (`session_token` / `media_session`).
     - If absent, inspects `x-device-id`: checks `devices` table to see if the device was previously paired to an account.
     - Fallback: returns `None` for unauthenticated guests.
3. **Precedence Hierarchy (`ProgressService::get_progress`):**
   - **Step 1:** If caller is authenticated (`user_id = Some(uid)`), query `progress WHERE user_id = $1 AND filename = $2`. If found, return it.
   - **Step 2:** If `device_id` is present, query `device_watch_history WHERE device_id = $1 AND filename = $2`.
   - **Step 3:** If caller is unauthenticated (`user_id = None`), fall back to guest progress `progress WHERE user_id IS NULL AND filename = $1`.
   - **Step 4:** Return `{ position: 0.0, duration: 0.0 }`.
4. **Progress Persistence (`ProgressService::update_progress`):**
   - Upserts into `progress (user_id, filename, position, duration, updated_at)` with `ON CONFLICT (user_id, filename) DO UPDATE`.
   - If `device_id` is present, links `user_id` in `devices` table and records hardware history in `device_watch_history`.
5. **Catalog & Details Integration (`MovieService::list_movies` & `get_movie_details`):**
   - Resolves `user_id` from caller headers.
   - Left-joins `progress` matching the authenticated user's `user_id` (or `user_id IS NULL` for guests).
   - "Continue Watching" rails and movie details cards now reflect personal progress across any device.

---

## 3. Verification & Test Outcomes

### 1. Dedicated Rust Integration Test Suite (`rust/tests/user_progress_test.rs`)
Ran `cargo test --manifest-path rust/Cargo.toml --test user_progress_test`:
```text
running 4 tests
test test_cascading_user_delete_progress ... ok
test test_cross_device_progress_sync ... ok
test test_guest_progress_isolation ... ok
test test_user_progress_isolation ... ok

test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.71s
```
- **`test_user_progress_isolation`:** Verified User A (100s) and User B (50s) maintain completely isolated progress on the same movie file.
- **`test_cross_device_progress_sync`:** Verified User A updating progress on Phone (`dev_phone`) immediately syncs to User A on TV (`dev_tv`).
- **`test_guest_progress_isolation`:** Verified unauthenticated guest progress does not pollute signed-in user accounts.
- **`test_cascading_user_delete_progress`:** Verified that deleting a user account cleanly cascades and removes their progress rows.

### 2. API Contract Tests & Android Probe
- **Cargo API Contract Suite:** `cargo test --test api_contracts_test` passed 4/4 tests:
  - `test_health_endpoints` ... ok
  - `test_system_status_endpoint` ... ok
  - `test_movies_list_endpoint` ... ok
  - `test_movie_details_endpoint` ... ok
- **Android Client Probe:** Ran `python scripts/probe_android_api.py` against live service:
  - All 22 Android client endpoints answered with 100% contract compliance (`/api/progress`, `/api/movies`, `/api/movie/*`, etc.).

### 3. Full Web Frontend Test Suite
- Ran Vitest suite in `web/`: **46 test files passed (46/46), 334 tests passed (334/334)** in 50.24s.

### 4. Production Service Status
- Rebuilt optimized release binary via `scripts/cargo.bat build --release` (1m 27s).
- Restarted `MediaServerRust` Windows Service.
- Verified local and remote HTTPS endpoints:
  - `GET http://127.0.0.1:8000/health`: `200 OK` (`"engine": "rust", "status": "healthy"`)
  - `GET https://media.anisparvez.in/health`: `200 OK` (`"engine": "rust", "status": "healthy"`)

---

## 4. Deliverables Summary

| File | Purpose |
|---|---|
| [`rust/src/db.rs`](../rust/src/db.rs) | Migrated `progress` schema to add `user_id`, surrogate PK, and `UNIQUE NULLS NOT DISTINCT (user_id, filename)` |
| [`rust/src/services/auth_service.rs`](../rust/src/services/auth_service.rs) | Added `resolve_effective_user_id` helper combining session cookie and device linkage |
| [`rust/src/services/progress_service.rs`](../rust/src/services/progress_service.rs) | Updated `get_progress` and `update_progress` with Option A user-scoped precedence |
| [`rust/src/routes/progress.rs`](../rust/src/routes/progress.rs) | Extracted effective `user_id` from headers and passed to `ProgressService` |
| [`rust/src/services/movie_service.rs`](../rust/src/services/movie_service.rs) | Updated `list_movies` and `get_movie_details` to join user-scoped progress |
| [`rust/src/routes/movies.rs`](../rust/src/routes/movies.rs) | Resolved caller `user_id` and passed into `MovieService` |
| [`rust/src/services/preview_service.rs`](../rust/src/services/preview_service.rs) | Added `LIMIT 1` defensive guard to duration check |
| [`rust/tests/user_progress_test.rs`](../rust/tests/user_progress_test.rs) | Dedicated 4-test suite validating user isolation, cross-device sync, guest isolation, and cascades |
| [`docs/PLAN_USER_PROGRESS_SCOPING.md`](../docs/PLAN_USER_PROGRESS_SCOPING.md) | Approved implementation plan |
| [`docs/WALKTHROUGH_USER_PROGRESS_SCOPING.md`](../docs/WALKTHROUGH_USER_PROGRESS_SCOPING.md) | This completion walkthrough and verification report |
