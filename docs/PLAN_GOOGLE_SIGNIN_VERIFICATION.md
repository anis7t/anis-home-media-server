# Implementation Plan — Sub-item 3.3: Google Sign-In Post-Fix Verification

- **Date:** 2026-10-24
- **Author:** Antigravity (Advanced Agentic Pair Programmer)
- **Status:** 📋 **PENDING USER APPROVAL**
- **Target Tracking:** Category 3.3 in [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md), [`docs/Current issues.md`](Current%20issues.md)

---

## 1. Context & Background

On 2026-10-23, Google OAuth logins for valid Google accounts were encountering `403 Forbidden` (`{"error":"This account is not permitted to use this server."}`) because the production PostgreSQL database retained a stale test allowlist (`settings.auth_allowlist`).

This was resolved by:
1. Clearing `settings.auth_allowlist` (leaving it empty).
2. Updating `AuthService::allowlist_allows` so that an empty allowlist permits any authentic Google account to sign in (defaulting to viewer).
3. Enforcing that only accounts listed in `MEDIA_SERVER_ADMIN_EMAILS` (specifically `anis7t@gmail.com`) are promoted to `role: 'admin'`.

While unit and route tests in Rust verified the logic, the open item requires verifying that the fix is 100% operational in production:
- That the owner account `anis7t@gmail.com` signs in without 403 barriers.
- That the landing identity in `users` and `sessions` is strictly `admin`.
- That `/api/auth/me`, `/api/admin/status`, and administrative controls on `/account` and `/manage` reflect full verified admin privileges.

---

## 2. Scope

### In Scope
- **Configuration & Secret Verification:**
  - Verify `.env` parameters: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `MEDIA_SERVER_ADMIN_EMAILS`, and `MEDIA_SERVER_PUBLIC_BASE_URL`.
- **Database & Session Integrity Check:**
  - Verify `users` table row for `anis7t@gmail.com` (`role = 'admin'`).
  - Verify `sessions` table row for `anis7t@gmail.com` (`role = 'admin'`).
- **Live Endpoint Verification:**
  - Verify `GET /api/auth/google/login` returns valid redirect to Google OAuth endpoint with correct `client_id` and `redirect_uri`.
  - Verify `GET /api/auth/me` returns `authenticated: true`, `role: "admin"`, `is_admin: true`.
  - Verify `GET /api/admin/status` returns `is_admin: true`.
  - Verify public HTTPS ingress on `https://media.anisparvez.in`.
- **Automated Verification Utility (`scripts/verify_google_auth.ps1`):**
  - Create a host test script that validates the OAuth configuration, database rows, and session resolution automatically.
- **Documentation & Walkthrough:**
  - Update `docs/PROJECT_STATUS.md` and `docs/Current issues.md`.
  - Author completion walkthrough [`docs/WALKTHROUGH_GOOGLE_SIGNIN_VERIFICATION.md`](WALKTHROUGH_GOOGLE_SIGNIN_VERIFICATION.md).

### Out of Scope
- Changing Google OAuth credentials or callback URI on Google Cloud Console.
- Altering the user-facing login flow.

---

## 3. Implementation Steps

### Step 1: Automated Auth Audit Utility (`scripts/verify_google_auth.ps1`)
1. Create a script that checks:
   - Presence and formatting of `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and `MEDIA_SERVER_ADMIN_EMAILS` in `.env`.
   - Live PostgreSQL database verification: checks `users` for `anis7t@gmail.com` and asserts `role == 'admin'`.
   - Checks active sessions for `anis7t@gmail.com`.
   - Checks `GET /api/auth/google/login` response (HTTP 307 / 303 redirect to `accounts.google.com`).
   - Checks `GET /api/auth/me` with session token (verifying role `admin`).

### Step 2: Live Verification Against Local & Remote Ingress
1. Run `scripts/verify_google_auth.ps1` against `http://127.0.0.1:8000`.
2. Probe public ingress `https://media.anisparvez.in/api/auth/me`.
3. Confirm that the UI on `/account` reflects `Signed in as Anis Parvez (anis7t@gmail.com)` with the `ADMIN` badge and the **Admin Security** card.

### Step 3: Documentation & Closeout
1. Update `docs/PROJECT_STATUS.md` marking Category 3 (Owner Security & Credential Actions) 100% resolved.
2. Produce walkthrough `docs/WALKTHROUGH_GOOGLE_SIGNIN_VERIFICATION.md`.

---

## 4. Exit Criteria

- [ ] `scripts/verify_google_auth.ps1` passes all checks (env vars, DB user role, DB session role, OAuth endpoint, and `/api/auth/me`).
- [ ] `users` table records `anis7t@gmail.com` with `role = 'admin'`.
- [ ] `GET /api/auth/me` and `GET /api/admin/status` return `role: "admin"` and `is_admin: true` on both local (`127.0.0.1:8000`) and public HTTPS (`media.anisparvez.in`).
- [ ] Full Category 3 closeout documented in `docs/PROJECT_STATUS.md` and walkthrough delivered.

---

## 5. Risks & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Stale session cookie in browser | Browser shows guest or viewer state | User can sign out and sign in again via Google OAuth; or Admin PIN can be used as fallback. |
| Host header spoofing during OAuth callback | Invalid redirect URI | `MEDIA_SERVER_PUBLIC_BASE_URL` is pinned to `https://media.anisparvez.in` so callback URLs are always trusted. |

---

## 6. Open Decisions for User

1. **Verification Approach:**
   - **Option A (Recommended):** Run the automated host verification script (`scripts/verify_google_auth.ps1`) and verify live API endpoints locally and over HTTPS, with owner confirming their browser session on `/account`.
   - **Option B:** Owner logs out and performs a fresh live Google login in their desktop browser right now while we monitor server logs.
