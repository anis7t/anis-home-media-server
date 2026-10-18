# Implementation Plan: Google OAuth 502 Fix & Admin Auth Configuration

**Date:** 2026-10-18  
**Branch:** `feat/active-transcoding-dashboard`  
**Tracking Issue:** Cloudflare 502 Bad Gateway on Google OAuth Callback & Admin Role PIN Requirement on LAN  

---

## 1. Problem Statement & Root Cause Analysis

### A. Cloudflare 502 Bad Gateway on Google OAuth
When a user attempts Google Sign-In via `https://media.anisparvez.in`, the browser redirects to Google and returns to:
`https://media.anisparvez.in/auth/google/callback?state=...&code=...`
Cloudflare returns:
```text
Bad gateway Error code 502
media.anisparvez.in Host Error
```
And `rust_api.log` records:
```text
2026-10-18T10:48:58.609363Z ERROR tower_http::trace::on_failure: response failed classification=Status code: 502 Bad Gateway latency=747 ms
```

**Root Cause:**
In [`rust/src/services/auth_service.rs`](file:///e:/MediaServer/rust/src/services/auth_service.rs#L668-L670):
```rust
let mut hasher = Sha256::new();
hasher.update(verifier.as_bytes());
let challenge = hex::encode(hasher.finalize());
```
RFC 7636 §4.2 (OAuth 2.0 PKCE) specifies:
$$\text{code\_challenge} = \text{BASE64URL-ENCODE}(\text{SHA256}(\text{ASCII}(\text{code\_verifier})))$$
without trailing padding (`=`).
Currently, `auth_service.rs` hex-encodes the SHA-256 hash (64 hex characters `0-9a-f`). Google's authorization server computes `base64url(sha256(verifier))` (43 URL-safe base64 characters) and compares it with `code_challenge`. Because hex encoding differs from base64url, Google rejects the token exchange with `HTTP 400 Bad Request`.
In `auth_service.rs` line 771, non-200 responses return `AppError::BadGateway`, which maps to HTTP `502 Bad Gateway`. Cloudflare forwards this 502 status directly as a host failure. Furthermore, the error body returned by Google was not logged.

### B. Admin PIN "6361" Invalid on Manage Page & LAN Authentication Invariant
The user clarified: *"5. admin login required for admin role in lan as well"* while *"no i dont want lan login for now"* applies to general library browsing.
- **LAN Browsing Policy:** General viewing, browsing, search, and playback on LAN require zero login prompts and are never locked behind a login gate.
- **Admin Invariant Policy:** Privileged admin capabilities (accessing `/manage`, deleting movies, changing storage retention policies, purging caches) **strictly require admin authorization** (via Admin PIN or authenticated Google Admin session) across both LAN and remote WAN.
- **Why PIN `6361` Failed:**
  Integration tests (`tests/auth_pin_login_test.rs` and `tests/devices_test.rs`) repeatedly executed `INSERT INTO settings (key, value) VALUES ('admin_pin', '998877') ON CONFLICT DO UPDATE...` against the shared PostgreSQL database, quietly overwriting the user's PIN `6361` with `'998877'`. When the user entered `6361` on the Manage page, verification failed.

---

## 2. Scope

### In Scope
1. **RFC 7636 Base64URL PKCE Implementation:**
   - Implement standard unpadded Base64URL encoding for `code_challenge` in [`rust/src/services/auth_service.rs`](file:///e:/MediaServer/rust/src/services/auth_service.rs).
   - Add detailed error logging for Google token exchange responses (status code + response text) to ensure rapid diagnosis of any future upstream OAuth issues.
2. **Admin PIN Persistence & Database Integrity:**
   - Restore `admin_pin` in `settings` table to `'6361'`.
   - Update integration tests in `rust/tests/` so that any test modifying `admin_pin` captures the existing PIN and restores `'6361'` in a clean teardown.
3. **LAN Experience & Admin Role Enforcement:**
   - Maintain seamless open library browsing and media playback on LAN without any login modal or login screen interruptions.
   - Strictly preserve admin gate for `/manage` and administrative API endpoints (`/api/storage/*`, `/api/admin/*`, deletion, purge), requiring PIN `6361` or an authenticated admin session across both LAN and WAN.
4. **Build, Service Restart & Live Verification:**
   - Recompile `rust/` in release mode.
   - Instruct service restart via `restart_rust_service.bat`.
   - Verify timestamp of `rust/target/release/media-server-api.exe`.
   - Test Admin PIN `6361` verification via `/api/admin/verify`.
   - Verify Google OAuth URL challenge format and callback flow.

### Deliberately Out of Scope
- Removing PIN protection from destructive administrative endpoints.
- Modifying Android TV / Fire TV pairing flow.

---

## 3. Exit Criteria
1. `AuthService::oauth_start` generates a 43-character URL-safe unpadded Base64URL `code_challenge` conforming to RFC 7636 §4.2.
2. Google OAuth token exchange succeeds on `https://media.anisparvez.in/auth/google/callback` without returning `502 Bad Gateway`.
3. Admin PIN `6361` succeeds on `/api/admin/verify` and unlocks `/manage` on both LAN and WAN.
4. General library browsing on LAN requires zero login prompts.
5. `admin_pin` remains `'6361'` in PostgreSQL and tests do not leave `'998877'` in the database.
6. All existing unit and integration tests pass with zero regressions.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Base64URL padding incompatibility** | Google rejects `code_challenge` if `=` padding is present | RFC 7636 §4.2 explicitly mandates unpadded base64url. Custom encoder will strictly omit `=` padding. |
| **Test suite pin pollution** | Future `cargo test` runs overwrite `admin_pin = 6361` | Tests in `rust/tests/` will be updated to restore `'6361'` in a teardown/cleanup block. |
| **Cloudflare edge caching of 502** | Browser or edge returns cached 502 | Cloudflare does not cache 502 status codes on dynamic routes (`/auth/*` has `Cache-Control: no-store`). |

---

## 5. Implementation Steps

1. **Implement Base64URL Encoder in [`rust/src/services/auth_service.rs`](file:///e:/MediaServer/rust/src/services/auth_service.rs):**
   - Add zero-dependency unpadded Base64URL encoder `base64url_encode(data: &[u8]) -> String`.
   - Update `challenge` in `oauth_start`:
     ```rust
     let mut hasher = Sha256::new();
     hasher.update(verifier.as_bytes());
     let challenge = base64url_encode(&hasher.finalize());
     ```
   - Enhance `oauth_callback` error handling to read and log Google error status and body text when token exchange fails.
2. **Database PIN Restoration & Test Isolation:**
   - Execute SQL: `UPDATE settings SET value = '6361' WHERE key = 'admin_pin'`.
   - Update `tests/auth_pin_login_test.rs` and `tests/devices_test.rs` to clean up/restore `'6361'`.
3. **Compile & Verification:**
   - `cargo build --release --manifest-path rust/Cargo.toml`.
   - Execute automated tests to confirm zero regressions.
   - Guide user to restart `MediaServerRust` via `restart_rust_service.bat`.
   - Verify live service and test PIN `6361` on `/manage`.
