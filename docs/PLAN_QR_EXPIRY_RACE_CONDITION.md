# Implementation Plan — QR Expiry & Finalize Status Race Condition (Category 5.3)

## 1. Executive Summary & Objective

- **Context:** The QR authentication flow (`/api/auth/qr/*`) enables camera-less devices (smart TVs, consoles, and desktop browsers) to sign in securely via a mobile device handshake. Currently, a 2-minute hard time-to-live (`expires_at`) governs `device_pair_sessions`.
- **Identified Defects:**
  1. **Expiry Boundary Race Condition:** If a phone user confirms the pairing near the end of the 2-minute window (e.g. with 1–2 seconds remaining), `confirm_pair_session()` succeeds and mints a 30-day session token, but leaves `expires_at` unchanged. By the time the TV receives the SSE event or poll notification and calls `GET /api/auth/qr/{id}/finalize`, `expires_at` has elapsed. The TV receives `400 Bad Request: "Pair session expired. Please start again."`, leaving the user stranded while an orphaned 30-day session remains in the database.
  2. **Non-Atomic / Replay-Vulnerable Finalization:** `qr_finalize_handler` reads `device_pair_sessions` without atomically marking the row as finalized or consumed in PostgreSQL.
  3. **Silent Drop on SSE Interruption:** In `web/src/hooks/useQrSession.ts`, when `es.onerror` fires (e.g. mobile hotspot or proxy drop), the EventSource closes without falling back to `/status` polling despite comments claiming it does.
  4. **Client Clock Drift Collision:** If a client's clock is slightly ahead of the server, the local countdown hits 0 and triggers `fetchSession()`, discarding an in-flight confirmation.
- **Objective:** Eliminate the boundary race condition with a 60-second confirmation grace extension, enforce atomic single-use finalization in PostgreSQL (`finalized BOOLEAN`), implement automatic status polling fallback on SSE interruption in `useQrSession.ts`, freeze timers upon confirmation, and verify the entire lifecycle with a dedicated Rust integration test suite (`rust/tests/qr_auth_test.rs`).

---

## 2. Proposed Changes & Architecture

### A. Database Schema (`rust/src/db.rs`)
1. In `ensure_schema()`, add `finalized` and `finalized_at` columns to `device_pair_sessions`:
   ```sql
   ALTER TABLE device_pair_sessions ADD COLUMN IF NOT EXISTS finalized BOOLEAN NOT NULL DEFAULT FALSE;
   ALTER TABLE device_pair_sessions ADD COLUMN IF NOT EXISTS finalized_at TIMESTAMPTZ;
   ```
2. Create index on active pair sessions for fast lookup:
   ```sql
   CREATE INDEX IF NOT EXISTS idx_device_pair_sessions_lookup
       ON device_pair_sessions (id, expires_at, confirmed, finalized);
   ```

### B. Backend Services & Handlers (`rust/src/services/auth_service.rs` & `rust/src/routes/qr_auth.rs`)
1. **Grace Window on Confirmation (`confirm_pair_session`):**
   - When the phone confirms a valid pairing code/sig, extend `expires_at` by a **60-second finalization grace window**:
     ```sql
     UPDATE device_pair_sessions
     SET confirmed = TRUE,
         user_id = $1,
         session_id = $2,
         device_name = $3,
         expires_at = GREATEST(expires_at, CURRENT_TIMESTAMP + INTERVAL '60 seconds')
     WHERE id = $4 AND confirmed = FALSE
     ```
   - This ensures the TV has ample time (60 seconds) to receive the push/poll event and complete the redirect to `/finalize`.
2. **Atomic Session Finalization (`finalize_pair_session`):**
   - Add `AuthService::finalize_pair_session(pool, qr_id, presented_secret)`:
     - Verifies `secret_hash` matches `presented_secret`.
     - Atomically marks `finalized = TRUE` and `finalized_at = CURRENT_TIMESTAMP` where `confirmed = TRUE` and `finalized = FALSE` and `expires_at > CURRENT_TIMESTAMP`.
     - Returns `Ok((session_id, device_name))`.
     - If the session was already finalized by an immediate duplicate request from the same client, return the existing session ID idempotently so client redirects don't fail.
3. **Opportunistic Expiry Sweeping:**
   - In `create_pair_session()`, periodically clean up expired rows older than 1 hour (`DELETE FROM device_pair_sessions WHERE expires_at < CURRENT_TIMESTAMP - INTERVAL '1 hour'`) to prevent table growth.

### C. Frontend Resilience (`web/src/hooks/useQrSession.ts`)
1. **Active Polling Fallback on SSE Drop:**
   - When `es.onerror` is triggered or EventSource fails, start a 3-second fallback interval polling `GET /api/auth/qr/{id}/status`.
   - If the status reports `"confirmed"`, navigate to `/finalize`.
2. **Timer Freeze on Confirmation:**
   - If `confirmed` is true or status is confirmed, immediately clear the countdown timer to prevent `fetchSession()` from refreshing over an in-flight authentication handshake.
3. **Optimistic Loading Feedback:**
   - When confirmed, maintain `confirmed: true` state in `useQrSession` so the UI can render "Device paired! Signing in..." before the browser redirect finishes.

### D. Scope Boundaries (What Deliberately Does NOT Change)
- **Zero Protocol/Shape Breakages:** The QR data structure, URL format (`/remotelogin?qr_id=...&code=...&sig=...`), and endpoints (`/create`, `/lookup`, `/wait`, `/status`, `/confirm`, `/finalize`) remain 100% backward-compatible.
- **Client Security Invariant:** Path-scoped cookie secret binding (`ms_qr_secret`) remains mandatory for `/finalize`.

---

## 3. Exit Criteria

- [ ] **Database Schema:** `finalized` and `finalized_at` columns and index added via `rust/src/db.rs`.
- [ ] **Backend Service:** `confirm_pair_session` applies 60-second grace extension upon confirmation; `finalize_pair_session` executes atomic single-use redemption.
- [ ] **Frontend Fallback:** `useQrSession.ts` falls back to `/api/auth/qr/{id}/status` polling when EventSource drops and freezes timer when confirmed.
- [ ] **Integration Test Suite:** Dedicated Rust integration test suite [`rust/tests/qr_auth_test.rs`](../rust/tests/qr_auth_test.rs) verifying:
  - Full happy path handshake (create -> wait/poll -> confirm -> finalize).
  - Confirmation near expiry (T - 1s) successfully extends grace window and finalizes cleanly without 400 error.
  - Finalize replay protection (atomic idempotency).
  - Finalize secret verification rejection on missing/incorrect `ms_qr_secret`.
- [ ] **Frontend Vitest Suite:** Updated `web/src/hooks/useQrSession.test.ts` verifying polling fallback and timer freeze on confirmation (334+ vitest tests passing).
- [ ] **Regression Suite:** `audit_log_test`, `user_progress_test`, `admin_auth_test`, and `api_contracts_test` pass with zero failures.
- [ ] **Production Deployment:** Release binary built and `MediaServerRust` running cleanly on port 8000.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Prolonging abandoned confirmed sessions** | A confirmed session not claimed within 60s could linger | 60 seconds is strictly bounded; unconfirmed sessions still strictly expire at 2 minutes. |
| **Race between multiple `/finalize` requests from same browser** | Redundant cookie set or duplicate redirect | Idempotent atomic query in PostgreSQL (`finalized = TRUE`) returns the minted `session_id` on first call and idempotent cached lookup on subsequent hits. |
| **SSE drop causing visual stall on TVs** | TV appears stuck on pending QR code | Automatic 3-second fallback polling interval activated immediately on EventSource error. |

---

## 5. Open Decisions

1. **Finalize Idempotency Window:**
   - **Option A (Recommended):** Allow a 10-second grace window where an already-finalized session can re-read its minted `session_id` if the client re-hits `/finalize` (e.g. on mobile/TV browser reload), then purge/fail closed thereafter.
   - **Option B:** Strict single-shot: the very first hit to `/finalize` returns the session cookie; any subsequent hit immediately returns `410 Gone` or `400 Bad Request`.
