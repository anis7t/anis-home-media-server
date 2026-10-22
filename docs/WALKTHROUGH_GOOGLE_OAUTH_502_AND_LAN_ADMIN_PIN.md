# Walkthrough: Google OAuth 502 Fix & Admin Role PIN Hardening

**Date:** 2026-10-18  
**Branch:** `feat/active-transcoding-dashboard`  
**Commit:** `75cfed0`  

---

## 1. Overview & Context

This walkthrough documents the resolution for:
1. **Cloudflare 502 Bad Gateway on Google OAuth Callback:** Clicking "Sign in" via `https://media.anisparvez.in` returned HTTP 502 Bad Gateway when Google redirected back to `/auth/google/callback`.
2. **Admin PIN "[admin-pin]" Verification on Manage Page:** Resolving why entering `[admin-pin]` reported "invalid admin pin" while maintaining the policy that administrative capabilities strictly require admin authorization across both LAN and WAN.

---

## 2. Root Cause Analysis & Changes

### A. RFC 7636 PKCE Base64URL Encoding (Google OAuth 502)
- **Problem:** In [`rust/src/services/auth_service.rs`](file:///e:/MediaServer/rust/src/services/auth_service.rs), the OAuth 2.0 PKCE `code_challenge` was computed as `hex::encode(hasher.finalize())` (64 hexadecimal characters). Under RFC 7636 §4.2, Google requires an unpadded URL-safe Base64 string (43 characters). When exchanging `code_verifier` with Google's `/token` endpoint, Google rejected the request with HTTP 400 Bad Request, causing Axum to emit `AppError::BadGateway` (HTTP 502).
- **Fix:**
  - Implemented `base64url_encode(data: &[u8]) -> String` using the URL-safe unpadded Base64 character set `[A-Za-z0-9-_]`.
  - Updated `oauth_start` to encode SHA-256 digests via `base64url_encode`.
  - Added unit test `test_rfc7636_pkce_challenge_vector` verifying the official RFC 7636 Appendix B test vector:
    `verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"` produces exact challenge `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`.
  - Added verbose logging in `oauth_callback` to capture HTTP status codes and error bodies if Google ever returns a non-200 response.

### B. Admin PIN Persistence & Test Fixture Isolation
- **Problem:** `tests/auth_pin_login_test.rs` and `tests/devices_test.rs` previously ran `INSERT INTO settings (key, value) VALUES ('admin_pin', '998877')` and `DELETE FROM settings...` against the shared database without restoring the user's PIN `[admin-pin]`.
- **Fix:**
  - Restored `admin_pin = '[admin-pin]'` in PostgreSQL `settings` table.
  - Updated `tests/auth_pin_login_test.rs` to use `[admin-pin]` as the test PIN and restore `[admin-pin]` in teardown.
  - Updated `tests/devices_test.rs` to restore `[admin-pin]` during cleanup instead of deleting `admin_pin`.

---

## 3. Verification & Test Outcomes

### Unit & Integration Tests
1. **RFC 7636 Test Vector:**
   ```text
   running 1 test
   test services::auth_service::tests::test_rfc7636_pkce_challenge_vector ... ok
   ```
2. **PIN Login Flow & Session Verification:**
   ```text
   running 3 tests
   test test_auth_me_reports_oauth_configured ... ok
   test test_auth_google_redirects_when_unconfigured ... ok
   test test_login_pin_flow ... ok
   test result: ok. 3 passed; 0 failed; 0 ignored; finished in 4.91s
   ```
3. **Database Integrity Check:**
   - PostgreSQL `settings` table verified: `[('admin_pin', '[admin-pin]')]`.
4. **Release Compilation Check:**
   - `cargo check --release` succeeded with exit code 0 in 1m 49s.

---

## 4. Next Step: Service Restart

Per platform guidelines, because native backend Rust code was modified, the Windows Service must be restarted to apply the new binary.

**Instructions for User:**
Please run:
```bat
e:\MediaServer\scripts\restart_rust_service.bat
```
*(Accept the Administrator UAC prompt when it appears).*

This script will stop the service, compile the release binary with the new PKCE fix, restart `MediaServerRust`, and probe the `/health` endpoint. Once completed, both PIN `[admin-pin]` on `/manage` and Google Sign-In via `https://media.anisparvez.in` will be fully operational.
