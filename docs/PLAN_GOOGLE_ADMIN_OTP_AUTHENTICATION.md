# Implementation Plan — Replace Static Admin PIN with Google-Authenticated One-Time Admin Access (OTP)

**Document:** `docs/PLAN_GOOGLE_ADMIN_OTP_AUTHENTICATION.md`  
**Status:** PROPOSED — Awaiting User Approval  
**Date:** 2026-10-31  
**Author:** Antigravity  

---

## 1. Executive Summary & Objective

MediaServer administrative actions (storage policy changes, orphaned cache purging, library scans, connected device management, transcode job aborts) are currently gated by a static, shared administrator PIN stored in plaintext in the PostgreSQL `settings` table (`key = 'admin_pin'`) and duplicated across browser `sessionStorage` (`ms_admin_pin`) and client requests (`X-Admin-Pin`). Furthermore, a longstanding defect exists where frontend modals claim the PIN is 4 digits, but validation requires varying lengths up to 8.

This project permanently retires the static Admin PIN mechanism across the entire stack (Rust backend, React 19 frontend, Flutter client) and introduces a cryptographically secure, short-lived (5-minute), single-use **One-Time Admin Access Code (OTP)**. OTP generation is restricted exclusively to authenticated and authorized Google administrators.

---

## 2. Scope

### In-Scope:
1. **Database Schema & Migrations (`rust/src/db.rs`):**
   - New `admin_access_otps` table with fields: `id`, `admin_user_id`, `otp_hash`, `salt`, `created_at`, `expires_at`, `consumed_at`, `failed_attempts`, `lockout_until`.
   - Safe migration to purge legacy `admin_pin` from `settings` table.
   - Revocation and purge of legacy synthetic `admin_pin` user (`google_sub = 'admin_pin'`) and its active sessions.
   - Partial and compound indexes for fast single-use lookup and expiry cleanup.
2. **Backend Rust API & Security Services (`rust/src/`):**
   - Cryptographically secure 6-digit OTP generation (`getrandom` / OS CSPRNG).
   - Per-OTP salted cryptographic hashing (HMAC-SHA256 with per-record random salt) — zero plaintext storage.
   - Endpoints:
     - `POST /api/admin/otp/generate` (Google admin session only).
     - `POST /api/admin/otp/verify` (atomic single-use redemption, rate limiting, session minting/elevation).
     - `POST /api/admin/otp/revoke` (invalidation of outstanding OTPs).
   - Decommission legacy endpoints:
     - `POST /api/auth/login-pin` -> HTTP 410 Gone with explicit message.
     - `POST /api/admin/pin` -> HTTP 410 Gone.
     - `POST /api/admin/verify` -> route to OTP or session verification.
   - Update `AuthService::is_admin_authorized` to require valid admin session token (zero `X-Admin-Pin` header fallback).
   - Audit logging for OTP generation, redemption, revocation, and failed verification.
3. **React 19 SPA Frontend (`web/src/`):**
   - Redesign `AccountPage.tsx` "Admin Security" section:
     - "Generate Admin Access Code" action.
     - 6-digit code display with single-use warning.
     - 5-minute visible countdown timer (`mm:ss`).
     - One-click copy code action with feedback.
     - Revoke code action.
     - Expired and consumed state transitions.
   - Redesign `AdminPinModal.tsx` -> "Administrator Verification":
     - 6 individual numeric input cells with automatic focus progression, backspace navigation, paste support, and numeric mobile keypad.
     - Generic invalid/expired feedback without leaking token state.
   - Update `AdminAccessGate.tsx` and `AdminPinSignInModal.tsx`.
   - Remove plaintext PIN storage from `sessionStorage` (`ms_admin_pin`) across all pages (`ManagePage`, `TranscodeDashboardPage`, `DevicesPage`, `LibraryPage`, `AuthProvider`).
   - Fix 4-digit vs 6-digit discrepancies throughout the web client.
4. **Flutter / Android TV Client (`flutter_client/`):**
   - Update `tv_admin_pin_pad.dart` to 6 digits, update UI copy to "One-Time Access Code", remove "remember PIN", connect to `POST /api/admin/otp/verify`.
   - Update `admin_pin_sheet.dart` to 6 digits, connect to OTP verification.
   - Retire `change_pin_sheet.dart` and remove static PIN rotation actions.
   - Remove `adminPin` and `rememberAdminPin` from `AuthSecureStorage` and `storage_keys.dart`.
5. **Testing & Verification:**
   - 16 core test scenarios covering generation, expiry, single-use atomicity, race conditions, brute-force protection, isolation across administrators, and legacy retirement.
   - Rust unit & integration test suite (`.\scripts\cargo.bat test`).
   - React test suite (`npm --prefix web run test`).
   - Flutter analysis and tests (`flutter analyze`, `flutter test`).
   - Android API contract probe (`python scripts/probe_android_api.py`).

### Out-of-Scope (Deliberately Not Modified):
- Google OAuth core flow and PKCE exchange logic (`/api/auth/login`, `/api/auth/callback`).
- QR code remote login protocol (`device_pair_sessions` — already secure and independent).
- Video transcoding pipeline and direct play streaming mechanics.

---

## 3. Architecture & Data Flow

```text
[Google Administrator]
       │
       ▼ (1) Google OAuth 2.0 Sign-In
[Session Established (role: 'admin')]
       │
       ▼ (2) POST /api/admin/otp/generate
[Rust Backend]
  ├── Verify Google Admin session + allowlist
  ├── Invalidate any existing unconsumed OTP for this admin
  ├── Generate 6-digit CSPRNG code: "849201"
  ├── Generate 16-byte random salt
  ├── Compute HMAC-SHA256(salt, code)
  └── Store hash, salt, expires_at (NOW + 5 min) in `admin_access_otps`
       │
       ▼ Returns { "otp": "849201", "expires_in": 300, "expires_at": ... }
[Admin Account UI]
  ├── Displays "849201" once with 5-minute countdown timer
  └── Copy / Revoke actions (never saved in localStorage/sessionStorage)
       │
       ▼ (3) Admin Enters Code on TV / Unlocked Device
[TV / Web Client]
  └── POST /api/admin/otp/verify { "otp": "849201" }
       │
       ▼
[Rust Backend Verification]
  ├── Format validation: exactly 6 digits
  ├── Rate limit & brute-force check (< 5 failed attempts per OTP / IP window)
  ├── Constant-time hash verification against active OTPs
  ├── Atomic UPDATE ... SET consumed_at = NOW WHERE id = $1 AND consumed_at IS NULL
  │     └─ (Guarantees atomic, single-use execution with zero race conditions)
  ├── Mint or elevate session to admin role
  └── Return { "success": true, "admin": true, "session_token": "sess_..." }
```

---

## 4. Database Schema Design (`admin_access_otps`)

```sql
CREATE TABLE IF NOT EXISTS admin_access_otps (
    id              BIGSERIAL PRIMARY KEY,
    admin_user_id   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    otp_hash        TEXT NOT NULL,
    salt            TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at      TIMESTAMPTZ NOT NULL,
    consumed_at     TIMESTAMPTZ,
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    lockout_until   TIMESTAMPTZ
);

-- Fast probe index for unconsumed, unexpired OTPs
CREATE INDEX IF NOT EXISTS idx_admin_access_otps_active
    ON admin_access_otps (admin_user_id, expires_at)
    WHERE consumed_at IS NULL;

-- Cleanup migration in ensure_schema:
DELETE FROM settings WHERE key = 'admin_pin';
DELETE FROM users WHERE google_sub = 'admin_pin';
```

---

## 5. API Contracts

### 5.1 `POST /api/admin/otp/generate`
- **Headers:** `Cookie: session_token=sess_...` (must be authenticated Google admin).
- **Checks:**
  - `identity.is_admin == true` AND `identity.role == 'admin'`
  - `AuthService::role_for_email(&identity.email) == "admin"` (configured in `MEDIA_SERVER_ADMIN_EMAILS`)
  - Session is unexpired and active.
- **Action:**
  - Invalidates any pending unconsumed OTPs for `admin_user_id`.
  - Mints 6-digit numeric OTP via `getrandom`.
  - Computes salted hash with 16-byte random salt.
  - Inserts into `admin_access_otps` with `expires_at = CURRENT_TIMESTAMP + INTERVAL '5 minutes'`.
  - Records audit log (`action: "otp_generated"`).
- **Response (200 OK):**
  ```json
  {
    "otp": "849201",
    "expires_at": "2026-10-31T23:55:00Z",
    "expires_in": 300
  }
  ```

### 5.2 `POST /api/admin/otp/verify`
- **Request Body:**
  ```json
  {
    "otp": "849201",
    "admin_email": "admin@example.com" // Optional: used when multiple admins exist and request is unauthenticated
  }
  ```
- **Validation:**
  - Validates `otp` matches regex `^\d{6}$`.
  - Rate limiting: checks IP and lockout table.
- **Redemption & Atomicity:**
  - Scans active, unexpired OTPs (`consumed_at IS NULL AND expires_at > CURRENT_TIMESTAMP`).
  - If caller is already authenticated as an administrator or user, limits candidate OTPs strictly to their own `admin_user_id` (enforcing Administrator A cannot redeem Administrator B's OTP).
  - Uses constant-time comparison on hashes (`subtle::ConstantTimeEq`).
  - Performs atomic update:
    ```sql
    UPDATE admin_access_otps
    SET consumed_at = CURRENT_TIMESTAMP
    WHERE id = $1 AND consumed_at IS NULL AND expires_at > CURRENT_TIMESTAMP
    RETURNING id, admin_user_id
    ```
  - If 0 rows returned, redemption fails atomically.
- **On Success (200 OK):**
  - Mints new admin session or elevates existing session.
  - Sets `session_token` HTTP-only cookie.
  - Returns:
    ```json
    {
      "success": true,
      "admin": true,
      "session_token": "sess_...",
      "user": {
        "id": 1,
        "email": "admin@example.com",
        "role": "admin"
      }
    }
    ```
  - Records audit log (`action: "otp_redeemed"`).
- **On Failure (401 Unauthorized):**
  - Increments `failed_attempts` on matched candidate or tracks IP failures.
  - Returns generic message:
    ```json
    {
      "success": false,
      "error": "Invalid or expired access code"
    }
    ```
  - Never reveals whether the code was expired, already used, or wrong.

### 5.3 `POST /api/admin/otp/revoke`
- **Headers:** `Cookie: session_token=...` (authenticated Google admin).
- **Action:**
  - `UPDATE admin_access_otps SET consumed_at = CURRENT_TIMESTAMP WHERE admin_user_id = $1 AND consumed_at IS NULL`
  - Records audit log (`action: "otp_revoked"`).
- **Response (200 OK):**
  ```json
  {
    "success": true,
    "revoked": 1
  }
  ```

### 5.4 Legacy Endpoint Deprecations
- `POST /api/auth/login-pin` -> HTTP 410 Gone:
  ```json
  {
    "error": "Static Admin PIN login is retired. Use Google-authenticated One-Time Admin Access (OTP)."
  }
  ```
- `POST /api/admin/pin` -> HTTP 410 Gone:
  ```json
  {
    "error": "Static Admin PIN rotation is retired. Administrative access is now secured via Google-authenticated OTP."
  }
  ```

---

## 6. Frontend Redesign Details

### 6.1 Administrator Account Security Section (`AccountPage.tsx`)
- Displayed under `authenticated && role === 'admin'`.
- Interactive state:
  - Default: Card showing "Admin Security" with "Generate Admin Access Code" button and badge explaining single-use policy.
  - Active Code Generated:
    - 6 discrete large digits in stylized monospace badges.
    - Prominent countdown timer (`4:59` counting down every second in red/amber when under 1 min).
    - "Copy Code" button with clipboard API and toast feedback.
    - "Revoke Code" button with red accent.
    - Warning banner: *"Single-use only. Valid for 5 minutes. Do not share."*
  - Expired / Consumed State: Automatically transitions when countdown reaches 0 or when redemption occurs.
- Plaintext OTP stored strictly in React state memory; cleared on unmount, page refresh, or logout. Zero `localStorage` or `sessionStorage` footprint.

### 6.2 Administrator Verification Modal (`AdminPinModal.tsx`)
- Renamed and restyled as **Administrator Verification**.
- Subtitle: *"Enter your six-digit one-time access code"*.
- Six individual `<input>` cells (`type="text"`, `inputMode="numeric"`, `pattern="[0-9]*"`, `maxLength={1}`).
- Automatic focus movement to next input upon digit entry.
- Backspace key deletes digit and returns focus to previous input.
- Paste listener: intercepts clipboard paste, extracts first 6 numeric digits, fills all 6 inputs, and triggers submit.
- Verification loader and generic error banner.
- Option link: *"Need a code? Open Account to generate one."*

### 6.3 Purge Plaintext PIN Storage
- Eliminate all `sessionStorage.getItem('ms_admin_pin')` and `localStorage.getItem('admin_pin')`.
- Remove `X-Admin-Pin` header injection in API requests.
- Client privileges rely exclusively on `user.role === 'admin'` and authenticated HTTP cookies/tokens.

---

## 7. Flutter / Android TV Redesign Details

### 7.1 TV Remote Keypad (`tv_admin_pin_pad.dart`)
- Update layout from 4 boxes to 6 digit indicator dots/boxes.
- Update constraints: `_enteredDigits.length == 6`.
- Remove "Remember PIN" checkbox / switch.
- Update header to: *"One-Time Access Code"*.
- Subtitle: *"Enter the 6-digit access code generated from your Administrator Account"*.
- Connect submission to `POST /api/admin/otp/verify`.

### 7.2 Mobile Bottom Sheet (`admin_pin_sheet.dart`)
- Update constraints: exactly 6 digits (`maxLength: 6`).
- Remove "Remember PIN" option.
- Call OTP verification API.

### 7.3 Settings Cleanup
- Remove `change_pin_sheet.dart` from settings screens.
- Purge `adminPin` and `rememberAdminPin` keys from `AuthSecureStorage`.

---

## 8. Defect Resolution: 4-Digit vs 6-Digit Discrepancies

A comprehensive repository audit will replace all 4-digit constraints:
- `AdminPinModal.tsx`: replace "Enter your 4-digit PIN" with 6-digit cell layout.
- `ChangeAdminPinModal.tsx`: retired.
- `tv_admin_pin_pad.dart`: replace length 4 checks with length 6.
- `admin_pin_sheet.dart`: enforce exactly 6 numeric digits.
- Rust request validation: enforce `regex::Regex::new(r"^\d{6}$")`.
- Test fixtures and mock data: update to 6-digit tokens.

---

## 9. Comprehensive Testing Matrix (16 Scenarios)

| # | Test Scenario | Expected Outcome | Layer |
|---|---|---|---|
| 1 | Authorized Google administrator generates OTP | Returns 200 OK with 6-digit OTP and 300s expiry | Rust Integration |
| 2 | Unauthenticated user generates OTP | Returns 401 Unauthorized | Rust Integration |
| 3 | Non-admin Google user generates OTP | Returns 403 Forbidden | Rust Integration |
| 4 | OTP validation format check | Exactly 6 numeric digits (`000000`–`999999`) | Rust Unit |
| 5 | OTP expires after 5 minutes | Verification after 301 seconds fails with 401 Unauthorized | Rust Integration |
| 6 | OTP redemption success | Single redemption succeeds and returns admin session | Rust Integration |
| 7 | Reusing consumed OTP | Second redemption attempt immediately fails with 401 | Rust Integration |
| 8 | Expired OTP redemption | Fails with generic 401 Unauthorized error | Rust Integration |
| 9 | Incorrect OTP redemption | Fails with generic 401 Unauthorized error | Rust Integration |
| 10 | Admin A cannot redeem Admin B's OTP | Cross-admin redemption attempt fails | Rust Integration |
| 11 | Generating new OTP invalidates previous unused OTP | Old OTP immediately fails verification | Rust Integration |
| 12 | Concurrent redemption race condition | Only 1 concurrent request succeeds; second fails atomically | Rust Concurrency Test |
| 13 | Logout and revocation invalidate OTP | Calling logout/revoke marks active OTPs consumed | Rust Integration |
| 14 | Rate limiting & brute force protection | >5 failed attempts locks verification temporarily | Rust Integration |
| 15 | Static PIN endpoints retired | `login-pin` and `admin/pin` return 410 Gone; `X-Admin-Pin` ignored | Rust Integration |
| 16 | React & Flutter enforce 6-digit input | Modals and pads require exactly 6 digits | React / Flutter Tests |

---

## 10. Risks & Mitigation

1. **Risk:** Legacy clients sending `X-Admin-Pin` header might unexpectedly fail admin actions.  
   **Mitigation:** The web frontend and Flutter client are updated simultaneously. Clear migration notice returned on legacy endpoints (`410 Gone`).
2. **Risk:** Brute-force guessing of 6-digit codes (1,000,000 combinations) during the 5-minute window.  
   **Mitigation:** Strict rate limiting (max 5 failed attempts per OTP record/IP window) and per-OTP salted hashing.
3. **Risk:** Race conditions during concurrent OTP redemption.  
   **Mitigation:** Atomic SQL update with `WHERE consumed_at IS NULL AND expires_at > CURRENT_TIMESTAMP RETURNING id`.
4. **Risk:** Secret leakage in logs or responses.  
   **Mitigation:** OTP is returned ONLY once in `generate` response; never logged; only salted hash is stored.

---

## 11. Open Decisions for User Confirmation

1. **OTP Display Format:** Random 6-digit number formatted as `000000`–`999999` (e.g. `849201`) or `100000`–`999999` (to avoid leading zero confusion). *(Recommendation: `100000`–`999999` 6 digits).*
2. **Session Lifespan on OTP Redemption:** When an OTP is redeemed on an unauthenticated client (e.g., Android TV), should the established administrative session be standard 30-day session or a bounded elevated session (e.g. 24 hours)? *(Recommendation: Standard 30-day session with admin role, revocable anytime from Connected Devices).*

---

## 12. Exit Criteria

- [ ] PostgreSQL migration creates `admin_access_otps` table and purges legacy `admin_pin` from `settings` and `users`.
- [ ] Rust endpoints `POST /api/admin/otp/generate`, `POST /api/admin/otp/verify`, `POST /api/admin/otp/revoke` implemented and tested.
- [ ] Legacy PIN endpoints return explicit 410 Gone; `X-Admin-Pin` header is completely decommissioned.
- [ ] React Account page features functional "Admin Security" OTP generator with visible 5-minute countdown and copy/revoke controls.
- [ ] React Admin Verification modal features 6 individual numeric inputs with auto-advance, backspace, and paste support.
- [ ] Flutter `tv_admin_pin_pad.dart` and `admin_pin_sheet.dart` enforce 6 digits and integrate with OTP verify.
- [ ] All 16 test matrix scenarios pass cleanly.
- [ ] Local parity suite (Rust formatting/clippy/tests, React build/typecheck/lint/tests, Flutter analyze/tests, Gitleaks) passes 100%.
- [ ] Final walkthrough document presented in chat.
