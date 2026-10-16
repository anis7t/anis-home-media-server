# Phase C5 Slice 4 Walkthrough: Authentication, Admin Session Parity & Reverse-Proxy Bridge Retirement

## 1. Overview & Objective

Phase C5 Slice 4 eliminates the final reverse-proxy bridge routes (`rust/src/routes/proxy.rs`) by porting all authentication, admin verification, allowlist management, and token handling natively to Rust Axum (`:8001`).

With this slice:
- **0 routes** are proxied to Flask (:8000). The proxy bridge module (`rust/src/routes/proxy.rs`) and its tests (`rust/tests/proxy_bridge_test.rs`) are **completely deleted**.
- All `/api/admin/*`, `/api/auth/*`, and `/auth/*` endpoints run 100% natively on Rust Axum backed by PostgreSQL.
- Strict adherence to `AGENTS.md` §4 (Admin Authorisation Invariants) is enforced:
  - Admin PIN fails closed when unset; no default PIN.
  - Accepts PIN only via `X-Admin-Pin` header or JSON body; never accepted via query string (`?pin=`).
  - Gated routes return 403 on unauthenticated/unauthorized access.

---

## 2. Key Changes Made

### A. Database Schema Migration (`rust/src/db.rs`)
Added transactional, idempotent DDL with advisory locking (`pg_advisory_xact_lock(7429184)`) for:
- `settings` (`key TEXT PRIMARY KEY, value TEXT`)
- `users` (`id BIGSERIAL PRIMARY KEY, google_sub TEXT UNIQUE, email TEXT, name TEXT, picture_url TEXT, role TEXT, ...`)
- `auth_tokens` (`id BIGSERIAL PRIMARY KEY, user_id BIGINT REFERENCES users(id), label TEXT, token_hash TEXT UNIQUE, ...`)
- `oauth_attempts` (`state TEXT PRIMARY KEY, nonce TEXT, verifier TEXT, redirect_uri TEXT, next_path TEXT, ...`)
- `sessions` (`id TEXT PRIMARY KEY, user_id BIGINT REFERENCES users(id), email TEXT, role TEXT, expires_at TIMESTAMPTZ, ...`)

### B. Core Service & Data Models (`rust/src/models/auth.rs`, `rust/src/services/auth_service.rs`)
- Models: `AccountResponse`, `AdminStatusResponse`, `AdminVerifyRequest`, `AdminVerifyResponse`, `AdminPinUpdateRequest`, `AllowlistResponse`, `TokenRecord`, `MintedToken`.
- `AuthService`:
  - `is_admin_authorized`: Verifies identity via session/bearer token or configured `admin_pin` (from `X-Admin-Pin` header or body). Fails closed.
  - `get_admin_status`: Reports `is_admin`, `has_pin`, and optional `user`.
  - `verify_admin_pin`: Accepts string, numeric, or alternate `admin_pin` key payloads; returns 200 on success, 401 on invalid/missing PIN.
  - `update_admin_pin`: Requires existing admin auth; enforces minimum 4 digits; updates database atomically.
  - `resolve_session_or_token`: Reads session cookies (`session_token`, `media_session`) or `Authorization: Bearer <token>` and validates active user session.
  - `get_allowlist` & `set_allowlist`: Reads and updates allowed email addresses from `settings` table and `MEDIA_SERVER_AUTH_ALLOWLIST` environment.
  - `list_tokens`, `create_token`, `revoke_token`: Manages personal access tokens (`ms_...` prefix, SHA-256 hashed on disk).
  - `pair_token`: Exchanges a device pairing token for an authenticated browser session cookie.
  - `oauth_start` & `oauth_callback`: Implements Google OAuth authorization flow with PKCE and state binding.
  - `logout_session`: Deletes active session and clears HTTP-only cookie.

### C. Native Route Handlers (`rust/src/routes/admin.rs`, `rust/src/routes/auth.rs`)
- Mounted under Axum router:
  - `GET /api/admin/status`
  - `POST /api/admin/verify`
  - `POST /api/admin/pin`
  - `GET /api/auth/me`
  - `GET /api/auth/allowlist` & `POST /api/auth/allowlist`
  - `GET /api/auth/tokens`, `POST /api/auth/tokens`, `DELETE /api/auth/tokens/{id}`
  - `GET /auth/google`, `GET /auth/google/callback`
  - `POST /auth/logout` & `GET /auth/logout`
  - `GET /auth/pair` & `POST /auth/pair`

### D. Reverse-Proxy Bridge Deletion (`rust/src/lib.rs`, `rust/src/routes/mod.rs`)
- Removed `proxy_routes` from `rust/src/lib.rs`.
- Removed `pub mod proxy;` from `rust/src/routes/mod.rs`.
- Deleted `rust/src/routes/proxy.rs` and `rust/tests/proxy_bridge_test.rs`.

---

## 3. Verification & Test Outcomes

### Integration Test Suites
1. **`rust/tests/admin_auth_test.rs`** (6/6 passing):
   - `test_admin_status_reports_has_pin_false_when_unset` (passed)
   - `test_admin_status_reports_has_pin_true_when_set` (passed)
   - `test_verify_pin_success_variations` (passed: exact string, numeric integer, `admin_pin` key, `X-Admin-Pin` header, whitespace padding)
   - `test_verify_pin_failure_cases` (passed: wrong PIN, empty string, null, empty JSON)
   - `test_verify_pin_fails_closed_when_pin_unset` (passed)
   - `test_admin_pin_rotation_lifecycle` (passed: 403 unauthenticated, 400 short PIN, 200 update, old PIN invalidated, new PIN verified)

2. **`rust/tests/auth_flow_test.rs`** (5/5 passing):
   - `test_auth_me_unauthenticated_returns_authenticated_false` (passed)
   - `test_allowlist_endpoints_and_validation` (passed: GET reports stored/env/effective, POST replaces list, 400 on non-string entries)
   - `test_tokens_bearer_token_cannot_mint_or_manage_tokens` (passed: 403 on GET, POST, DELETE with Bearer token)
   - `test_tokens_minting_validation_and_lifecycle` (passed: label required, negative validity rejected, mints `ms_` token with pairing URL, list, delete)
   - `test_pairing_device_lifecycle` (passed: GET pair page, POST exchanges token for `session_token` cookie, `/api/auth/me` resolves caller, logout clears cookie)

3. **Android Client Verification (`scripts/probe_android_api.py`)**:
   - 22/22 endpoints passed cleanly.
   - 0 proxied routes remain.
