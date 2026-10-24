# Implementation Plan — Per-User Playback Progress Scoping (Category 5.1)

## 1. Executive Summary & Objective

- **Context:** Currently, the PostgreSQL `progress` table stores video timeline playback positions globally per `filename` (`filename TEXT PRIMARY KEY`), with device-specific history tracked separately in `device_watch_history (device_id, filename)`. Consequently, if User A (`anis7t@gmail.com`) watches a movie on their laptop and later opens their phone or smart TV, cross-device resume positions are not unified under their account. Furthermore, multiple users or guests watching the same movie overwrite each other's global progress.
- **Objective:** Scope the `progress` table by `user_id` in PostgreSQL and the Rust Axum backend. Unify watch progress across all devices paired to the user's account, provide seamless fallback for guest viewers, and preserve 100% compatibility with the React SPA, Flutter client, and Android API contracts.

---

## 2. Proposed Changes & Architecture

### A. Database Schema (`rust/src/db.rs`)
1. **Schema Migration for `progress` Table:**
   - Add nullable foreign key column: `user_id BIGINT REFERENCES users(id) ON DELETE CASCADE`.
   - Drop the old single-column primary key constraint `progress_pkey` on `(filename)`.
   - Add surrogate primary key `id BIGSERIAL PRIMARY KEY`.
   - Add composite constraint: `CONSTRAINT uq_progress_user_filename UNIQUE NULLS NOT DISTINCT (user_id, filename)` (PostgreSQL 15+ feature fully supported on PostgreSQL 18.4).
   - Create indexing: `idx_progress_user_updated ON progress (user_id, updated_at DESC)` and `idx_progress_filename ON progress (filename)`.
   - Existing rows remain preserved with `user_id = NULL` (serving as legacy/guest progress).

### B. Progress Service & Routes (`rust/src/services/progress_service.rs` & `rust/src/routes/progress.rs`)
1. **Identity Extraction in Progress Route:**
   - In `rust/src/routes/progress.rs`, resolve caller identity:
     - Check `session_token` / `media_session` cookie via `AuthService::resolve_session_identity`.
     - If no session cookie, check if `x-device-id` is linked to a user in `devices WHERE device_id = $1 AND user_id IS NOT NULL`.
     - Extract `user_id: Option<i64>` and pass to `ProgressService`.
2. **Progress Retrieval Precedence (`get_progress`):**
   - **Step 1:** If `user_id` is present, query `progress WHERE user_id = $1 AND filename = $2`. If found, return it.
   - **Step 2:** If not found or if caller is a guest, query `device_watch_history WHERE device_id = $1 AND filename = $2` if `device_id` is provided. If found, return it.
   - **Step 3:** Fallback to guest progress `progress WHERE user_id IS NULL AND filename = $1`.
   - **Step 4:** Return `{ "position": 0.0, "duration": 0.0 }`.
3. **Progress Mutation (`update_progress`):**
   - Upsert into `progress (user_id, filename, position, duration, updated_at)`:
     ```sql
     INSERT INTO progress (user_id, filename, position, duration, updated_at)
     VALUES ($1, $2, $3::real, $4::real, CURRENT_TIMESTAMP)
     ON CONFLICT (user_id, filename) DO UPDATE SET
         position = EXCLUDED.position,
         duration = EXCLUDED.duration,
         updated_at = CURRENT_TIMESTAMP
     ```
   - If `device_id` is supplied, also upsert into `device_watch_history` to preserve device presence telemetry.

### C. Movie Catalog & Details Integration (`rust/src/services/movie_service.rs` & `rust/src/routes/movies.rs`)
1. **Identity Resolution in Movie Routes:**
   - Resolve `user_id: Option<i64>` from `headers` in `list_movies_handler` and `get_movie_details_handler`.
2. **Catalog Join:**
   - In `list_movies` and `get_movie_details`, join user-scoped progress when `user_id` is present:
     - Primary join: `progress p ON m.filename = p.filename AND p.user_id = $user_id`.
     - Fallback: If `user_id` is absent, join `progress p ON m.filename = p.filename AND p.user_id IS NULL`.
   - This ensures the "Continue Watching" carousel and details page reflect the signed-in user's personal resume points across all their screens.

### D. Scope Boundaries (What Deliberately Does NOT Change)
- **Wire Formats:** Request and response schemas for `/api/progress`, `/api/movies`, and `/api/movie/{filename}` remain completely unchanged.
- **Android & Flutter Clients:** No client app modifications required; `probe_android_api.py` continues to validate contracts.
- **Guest Access:** When unauthenticated, the system functions identically to the previous global progress model (`user_id = NULL`), preserving frictionless living-room TV playback.

---

## 3. Exit Criteria

- [ ] **Database Migration:** PostgreSQL schema migration succeeds cleanly in `ensure_schema()` on both live database and test fixtures.
- [ ] **Contract Integrity:** `python scripts/probe_android_api.py` passes 22/22 endpoints without regressions.
- [ ] **Automated Integration Test:** Dedicated Rust test suite (`rust/tests/user_progress_test.rs`) verifying:
  - User A and User B maintain completely isolated progress for the same movie.
  - Cross-device resume: Progress written by User A on Device 1 is returned to User A on Device 2.
  - Guest isolation: Unauthenticated requests do not leak User A or User B's playback positions.
  - Cascading deletes: Deleting a user cleans up their associated `progress` rows via foreign key cascade.
- [ ] **Full Regression Pass:** All existing Rust integration tests (`api_contracts_test`, `admin_auth_test`) pass.
- [ ] **Web Suite Verification:** All 46 Vitest test suites (334 tests) pass with zero errors.
- [ ] **Production Deployment:** Release binary compiled via `scripts/cargo.bat build --release`, `MediaServerRust` service restarted and verified healthy.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Dropping `progress_pkey` on live DB** | Could fail if foreign keys reference `progress(filename)` | Verified: No database tables reference `progress(filename)`. `ALTER TABLE progress DROP CONSTRAINT IF EXISTS progress_pkey` is completely safe. |
| **`NULLS NOT DISTINCT` support** | Syntax error on older PostgreSQL versions | Production database is PostgreSQL 18.4 (`MediaServerPG`), which natively supports standard SQL `UNIQUE NULLS NOT DISTINCT`. |
| **Guest playback regressions** | Unauthenticated viewers unable to save or resume progress | Retained explicit `user_id IS NULL` fallback path for both reads and writes. |

---

## 5. Open Decisions

1. **Progress Precedence for Paired Devices:**
   - **Option A (Recommended):** User-account progress takes top precedence. If a device is paired to a user, queries retrieve the user's unified progress across all devices, falling back to device-specific history only if no user row exists.
   - **Option B:** Strict device-specific precedence. Queries prioritize `device_watch_history` for that exact device first, and only fall back to user progress if the device has never played that movie.
