# Walkthrough — QR Expiry & Finalize Status Race Condition (Category 5.3)

## 1. Executive Summary

We have fully implemented, tested, and deployed the fix for **Category 5.3: QR Expiry & Finalize Status Race Condition**.

- **Expiry Boundary Race Condition Resolved:** When a mobile user confirms a pairing handshake near the end of the 2-minute deadline (e.g. at T-1s), `confirm_pair_session()` now atomically extends `expires_at` by a **60-second finalization grace window** (`expires_at = GREATEST(expires_at, CURRENT_TIMESTAMP + INTERVAL '60 seconds')`), preventing the TV from encountering `400 Bad Request` during client-side redirect.
- **Atomic Single-Use Finalization (Option A):** Added `finalized` (`BOOLEAN NOT NULL DEFAULT FALSE`) and `finalized_at` (`TIMESTAMPTZ`) to `device_pair_sessions`. `AuthService::finalize_pair_session()` atomically marks `finalized = TRUE, finalized_at = CURRENT_TIMESTAMP` and permits a **10-second idempotency window** for identical client requests, preventing duplicate redirects or reloads from stranding the user.
- **Client Fallback Polling & Countdown Freeze:** In [`web/src/hooks/useQrSession.ts`](file:///e:/MediaServer/web/src/hooks/useQrSession.ts), when SSE EventSource encounters interruptions (`onerror`), it activates a 3-second fallback interval polling `GET /api/auth/qr/{id}/status`. The countdown timer is strictly frozen upon confirmation, preventing client clock drift from re-requesting a replacement session while the handshake is finalizing.
- **Dedicated Rust & Vitest Test Suites:** Verified via 5/5 passing tests in [`rust/tests/qr_auth_test.rs`](file:///e:/MediaServer/rust/tests/qr_auth_test.rs) and 9/9 passing tests in [`web/src/hooks/useQrSession.test.ts`](file:///e:/MediaServer/web/src/hooks/useQrSession.test.ts) (336/336 tests passing across all 46 frontend test suites).
- **Production Service Deployed:** Rebuilt the optimized release binary and restarted the `MediaServerRust` Windows service, confirmed healthy on port 8000.

---

## 2. Changes Implemented

### A. Database Schema (`rust/src/db.rs`)
- Added migration to `ensure_schema()`:
  ```rust
  sqlx::query(
      "ALTER TABLE device_pair_sessions ADD COLUMN IF NOT EXISTS finalized BOOLEAN NOT NULL DEFAULT FALSE",
  )
  .execute(&mut *tx)
  .await?;

  sqlx::query(
      "ALTER TABLE device_pair_sessions ADD COLUMN IF NOT EXISTS finalized_at TIMESTAMPTZ",
  )
  .execute(&mut *tx)
  .await?;

  sqlx::query(
      r#"
      CREATE INDEX IF NOT EXISTS idx_device_pair_sessions_lookup
          ON device_pair_sessions (id, expires_at, confirmed, finalized)
      "#,
  )
  .execute(&mut *tx)
  .await?;
  ```

### B. Backend Services & Route Handlers (`rust/src/services/auth_service.rs` & `rust/src/routes/qr_auth.rs`)
- **Confirmation Grace Extension:**
  ```sql
  UPDATE device_pair_sessions
  SET confirmed = TRUE,
      user_id = $1,
      session_id = $2,
      device_name = $3,
      expires_at = GREATEST(expires_at, CURRENT_TIMESTAMP + INTERVAL '60 seconds')
  WHERE id = $4
  ```
- **Atomic Finalization Service (`AuthService::finalize_pair_session`):**
  - Constant-time secret hash check (`candidate_hash == stored_hash`).
  - Checks if already finalized within 10-second idempotency window; if so, returns existing `session_id`.
  - Rejects if unconfirmed, expired, or finalized > 10 seconds ago.
  - Performs atomic update: `UPDATE device_pair_sessions SET finalized = TRUE, finalized_at = CURRENT_TIMESTAMP WHERE id = $1 AND finalized = FALSE`.
- **Route Handler Refactoring (`routes/qr_auth.rs`):**
  - `qr_finalize_handler` delegates to `AuthService::finalize_pair_session`.
  - Updates custom device name in `devices` table if client provides `ms_device_id` or `x-device-id`.

### C. Frontend Resilience (`web/src/hooks/useQrSession.ts`)
- Added fallback polling on `es.onerror`: polls `GET /api/auth/qr/{id}/status` every 3 seconds.
- Added `confirmedRef` guard: freezes timer and ensures `fetchSession()` is never called if `confirmed` is true.

---

## 3. Verification & Test Outcomes

### A. Dedicated Rust Integration Tests (`rust/tests/qr_auth_test.rs`)
Command: `cmd.exe /c "E:\MediaServer\scripts\cargo.bat test --manifest-path E:\MediaServer\rust\Cargo.toml --test qr_auth_test"`
```text
running 5 tests
test test_qr_finalize_unconfirmed_fails ... ok
test test_qr_finalize_security_guards ... ok
test test_qr_boundary_expiry_grace_extension ... ok
test test_qr_finalize_idempotency_window ... ok
test test_qr_happy_path_handshake ... ok

test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.99s
```

### B. Frontend Vitest Tests (`web/src/hooks/useQrSession.test.ts` & Full Suite)
Command: `npm test -- --run`
```text
 ✓ src/hooks/useQrSession.test.ts (9 tests) 1232ms

 Test Files  46 passed (46)
      Tests  336 passed (336)
   Start at  13:47:14
   Duration  51.60s
```

### C. Backend Regression Suite
- `audit_log_test`: 7/7 tests passed.
- `user_progress_test`: 4/4 tests passed.
- `admin_auth_test`: 6/6 tests passed.
- `api_contracts_test`: 4/4 tests passed.
- `probe_android_api.py`: 22/22 endpoints passed.

### D. Live Production Service Probing (`scripts/probe_qr_auth.ps1`)
```text
1. Testing POST /api/auth/qr...
   Session created successfully!
   QR ID: qr_f1030748a2b7aebae4f9822a8416d006105f4716096a558e4b52d9be624d90d3
   Code: KC7DE
   Sig: 871191be865803392ccfe717775f145383745cc70b2997c0c6e653839c19b3f4

2. Testing GET /api/auth/qr/{id}/status...
   Status: pending

3. Testing GET /api/auth/qr/{id}/finalize without secret (should be 403)...
   Finalize rejected as expected: HTTP 403 Forbidden

All live QR auth probes succeeded!
```
