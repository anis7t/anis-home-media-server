# Phase C5 Slice 4 — Authentication, Admin Session Parity & Reverse-Proxy Bridge Retirement Plan

**Date:** 2026-10-16  
**Target Branch:** `feat/rust-transcode-worker`  
**Prerequisites:** Phase C5 Slice 1 (`68538e1`), Slice 2 (`1a30efd`), and Slice 3 (`8ce85b3`) complete & committed  
**Objective:** Port the remaining authentication and administrator session surface (`/auth/*`, `/api/auth/*`, `/api/admin/*`) natively to Rust Axum, completely delete `rust/src/routes/proxy.rs`, remove `flask_origin` and the reverse-proxy bridge from `rust/src/lib.rs`, and achieve 100% native independence in preparation for the `:8000` port swap.

> **Postscript (2026-10-23):** the token routes this plan ports (`/api/auth/tokens`,
> `/auth/pair`) and the `auth_tokens` table were retired. QR sign-in is the only pairing path;
> see [`docs/TRIAGE_06_ADD_DEVICE_FLOW.md`](TRIAGE_06_ADD_DEVICE_FLOW.md) §8.

---

## 1. Background & Migration Milestone

In Slices 1, 2, and 3, we eliminated:
- `/api/scan` and `/api/transcode/start` (Slice 1)
- `/api/devices/*` (Slice 2)
- `/api/storage/*` (Slice 3)

Only 3 route groups remain in the temporary reverse-proxy bridge in `rust/src/lib.rs`:
```rust
Router::new()
    .route("/auth", axum::routing::any(routes::proxy::proxy_handler))
    .route("/auth/{*path}", axum::routing::any(routes::proxy::proxy_handler))
    .route("/api/auth", axum::routing::any(routes::proxy::proxy_handler))
    .route("/api/auth/{*path}", axum::routing::any(routes::proxy::proxy_handler))
    .route("/api/admin", axum::routing::any(routes::proxy::proxy_handler))
    .route("/api/admin/{*path}", axum::routing::any(routes::proxy::proxy_handler))
    .with_state(proxy_state)
```

Porting these endpoints natively will retire the reverse-proxy bridge completely, paying down all remaining architectural debt per **`AGENTS.md` §0.2 (Native Independence Invariant)**.

---

## 2. Technical Specifications & Endpoints

### 2.1 Admin PIN & Status Management (`/api/admin/*`)

#### `GET /api/admin/status`
- **Functionality**:
  - Checks if an admin PIN is configured in PostgreSQL `settings` (`key = 'admin_pin'`).
  - Evaluates whether caller is currently authorized (via `X-Admin-Pin` header or active admin session cookie).
  - **Fail-Closed Rule (`AGENTS.md` §4)**: If `admin_pin` is empty or unset, `has_pin` is false and `is_authorized` is false. Never accepts PIN from query string.
- **Response Shape**:
  ```json
  {
    "has_pin": true,
    "is_authorized": true
  }
  ```

#### `POST /api/admin/verify`
- **Functionality**:
  - Accepts candidate PIN via `X-Admin-Pin` header or JSON body `{"pin": "..."}` or `{"admin_pin": "..."}`.
  - Queries `settings` for `admin_pin`.
  - Returns:
    ```json
    {
      "success": true,
      "authorized": true
    }
    ```
    If PIN is invalid or unset: returns `{"success": true, "authorized": false}` with HTTP 200 (matching contract).

#### `POST /api/admin/pin`
- **Functionality**:
  - Body: `{"new_pin": "...", "current_pin": Option<String>}`.
  - If a PIN is already configured in the database, caller **must** be authorized (either via valid `current_pin`, `X-Admin-Pin`, or admin session). If unauthorized, returns HTTP 403.
  - Validates `new_pin`: must be 4–8 digits/characters.
  - Upserts into PostgreSQL `settings`: `INSERT INTO settings (key, value) VALUES ('admin_pin', $1) ON CONFLICT (key) DO UPDATE SET value = $1`.
  - Returns HTTP 200 `{"success": true, "message": "Admin PIN updated successfully."}`.

---

### 2.2 Client Identity & Tokens (`/api/auth/*`)

#### `GET /api/auth/me`
- **Functionality**:
  - Inspects incoming session cookie (`session_token`) or `Authorization: Bearer <token>`.
  - Resolves user from `sessions` or `personal_access_tokens` table joined with `users`.
  - Also inspects `X-Admin-Pin` header: if valid admin PIN is presented, elevates `is_admin = true`.
- **Response Shape**:
  ```json
  {
    "authenticated": true,
    "user": {
      "id": 1,
      "email": "user@example.com",
      "name": "Anis",
      "picture": "https://..."
    },
    "is_admin": true
  }
  ```
  If unauthenticated:
  ```json
  {
    "authenticated": false,
    "user": null,
    "is_admin": false
  }
  ```

#### `GET /api/auth/allowlist` & `POST /api/auth/allowlist`
- **Functionality**:
  - Gated strictly by `is_admin_authorized`.
  - `GET`: Returns stored allowlist from `settings` table, environment fallback, and effective allowlist.
  - `POST`: Body `{"emails": ["..."]}`. Upserts allowlist into `settings` table (`key = 'auth_allowlist'`).

#### `GET /api/auth/tokens`, `POST /api/auth/tokens`, `DELETE /api/auth/tokens/{id}`
- **Functionality**:
  - Personal Access Tokens (PATs) for programmatic API access.
  - Persisted in PostgreSQL `personal_access_tokens` table.

---

### 2.3 Google OAuth Flow (`/auth/*`)

#### `GET /auth/google`
- Initiates authorization-code flow with PKCE (`code_challenge` / `code_verifier`).
- Redirects to Google OAuth endpoint `https://accounts.google.com/o/oauth2/v2/auth`.

#### `GET /auth/google/callback`
- Exchanges `code` with Google for ID token and access token.
- Verifies JWT signature and claims (iss, aud, email).
- Enforces email allowlist (`effective_allowlist`).
- Creates/updates `users` row and issues `session_token` cookie.
- Redirects to `/`.

#### `POST /auth/logout`
- Revokes session in `sessions` table and expires `session_token` cookie (`Max-Age=0`).

---

## 3. Scope

### In Scope for Slice 4:
1. **`rust/src/services/auth_service.rs`**:
   - Extend with session validation, user resolution, Google OAuth token exchange & verification, allowlist management, and PAT tokens.
2. **`rust/src/routes/admin.rs`**:
   - Handlers for `/api/admin/status`, `/api/admin/verify`, `/api/admin/pin`.
3. **`rust/src/routes/auth.rs`**:
   - Handlers for `GET /api/auth/me`, `GET/POST /api/auth/allowlist`, `/api/auth/tokens`, `GET /auth/google`, `GET /auth/google/callback`, `POST /auth/logout`.
4. **`rust/src/lib.rs`**:
   - Mount `admin_routes` and `auth_routes`.
   - **Delete `proxy_routes` completely and remove `routes::proxy`**.
5. **Comprehensive Tests**:
   - `rust/tests/admin_auth_test.rs`: Test PIN verification, fail-closed status, and PIN updates.
   - `rust/tests/auth_flow_test.rs`: Test `/api/auth/me`, allowlist management, and token issuance.
   - Clean up `proxy_bridge_test.rs` (replaced by native tests).

### Deliberately Out of Scope:
- Production port swap (`:8001` -> `:8000`) and NSSM service reconfiguration (deferred to Phase 7 final cutover).

---

## 4. Exit Criteria

1. **Proxy Bridge Completely Deleted**:
   - `rust/src/routes/proxy.rs` deleted from the codebase.
   - `flask_origin` removed from `create_app_full` and `lib.rs`.
   - Reverse-proxy bridge groups reduced from 3 to **ZERO (0)**.
2. **100% Native Auth & Admin**:
   - `GET /api/admin/status` reports real configuration and authorization state.
   - `POST /api/admin/verify` verifies PIN correctly from headers or body.
   - `POST /api/admin/pin` updates PIN with authorization checks.
   - `GET /api/auth/me` returns current authentication state for React SPA.
   - `/api/auth/allowlist` manages sign-in access.
3. **Test Suite Green**:
   - All tests in `rust/tests/` pass with zero failures (250+ tests).
   - `scripts/probe_android_api.py` passes 22/22.

---

## 5. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| **Accidental Open Admin Door** | Strictly follow `AGENTS.md` §4: Admin PIN fails closed when unset; never accept PIN from query string; verify destructive actions return 403 when unauthenticated. |
| **OAuth Credentials Missing in Dev** | If Google OAuth client credentials (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`) are not set in the environment, `/auth/google` returns clear 503 explaining configuration requirement, while PIN-based admin authentication remains fully functional. |
| **Session Cookie Tampering** | Store cryptographically secure random session tokens (32 bytes hex) in PostgreSQL `sessions` table; validate expiration and set `HttpOnly; SameSite=Lax; Path=/`. |

---

## 6. Open Decisions for User Confirmation

1. **Google OAuth Dependency in Rust**:
   - For native JWT ID token verification, should we use standard `jsonwebtoken` + Google OIDC jwks endpoint, or verify via Google's tokeninfo endpoint (`https://oauth2.googleapis.com/tokeninfo?id_token=...`)?  
   *(Recommended: Tokeninfo endpoint with local cache for simplicity and lightweight dependencies, or jsonwebtoken for offline verification)*.
2. **Ready to Proceed**:
   - Do you approve proceeding with the implementation of Phase C5 Slice 4 as outlined?
