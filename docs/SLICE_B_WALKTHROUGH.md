# Slice B Walkthrough: Google Sign-In 503 Resolution & Admin PIN Fallback

## 1. Executive Summary
- **Issue**: Clicking "Sign In" returned HTTP 503 (`"Sign-in is not configured on this server."`) when Google OAuth API credentials were not configured in `.env`. Users had no fallback route to authenticate on local networks.
- **Solution**:
  - Implemented an `oauth_configured` probe flag on `GET /api/auth/me`.
  - Redirected unconfigured `/auth/google` requests to `/account?error=oauth_unconfigured` rather than failing with raw HTTP 503.
  - Implemented `POST /api/auth/login-pin` with constant-time verification against `settings.admin_pin`, upserting an `admin_pin` administrator account and minting a standard 30-day `session_token` HTTP-only cookie.
  - Built an obsidian-glass `<AdminPinSignInModal>` (portaled to `document.body`) with direct PIN authentication, clear error feedback, and an `.env` Google OAuth setup guide.
  - Seamlessly wired `AuthProvider` and `AccountPage` to offer Admin PIN authentication directly and automatically trigger the dialog on unconfigured environments.

---

## 2. Key Code Changes

### Rust Backend
1. **`rust/src/models/auth.rs`**:
   - Extended `AccountResponse` with `oauth_configured: Option<bool>`.
   - Added `LoginPinPayload { pin: Option<String> }`.
2. **`rust/src/services/auth_service.rs`**:
   - `AuthService::is_oauth_configured()`: Inspects `google_client_id` and `google_client_secret`.
   - `AuthService::login_with_pin()`: Performs constant-time comparison against configured `admin_pin`, creates/upserts `admin_pin` account in `users`, and inserts a 30-day session token into `sessions`.
3. **`rust/src/routes/auth.rs`**:
   - `auth_me_handler`: Injects `oauth_configured: Some(service.is_oauth_configured())`.
   - `google_start_handler`: Detects missing credentials and redirects to `/account?error=oauth_unconfigured`.
   - `login_pin_handler`: Handles `POST /api/auth/login-pin`, returning `Set-Cookie: session_token=sess_<hex>; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000`.
4. **`rust/src/lib.rs`**:
   - Mounted `POST /api/auth/login-pin` under `/api/auth`.
5. **`rust/tests/auth_pin_login_test.rs`**:
   - Integration tests covering OAuth status reporting, redirect when unconfigured, invalid PIN refusal (401), and full session cookie issuance and validation via `/api/auth/me`.

### Web Client
1. **`web/src/lib/api/account.ts`**:
   - Added `oauth_configured?: boolean` to `AccountResponse`.
   - Added `loginWithPin(pin: string)`.
2. **`web/src/components/AdminPinSignInModal.tsx`**:
   - Obsidian-glass modal dialog portaled to `document.body`.
   - Secure PIN input, interactive `.env` configuration guide, and keyboard navigation (Escape to close, auto-focus).
3. **`web/src/components/AdminPinSignInModal.test.tsx`**:
   - 6/6 unit tests covering rendering, input submission, failure alerts, and keyboard interactions.
4. **`web/src/auth/AuthProvider.tsx`**:
   - Exposed `oauthConfigured` and `openPinSignIn()`.
   - Fallback `signIn()` directly opens the PIN modal when OAuth is not configured.
   - Rendered `<AdminPinSignInModal>` globally inside the provider.
5. **`web/src/features/account/AccountPage.tsx`**:
   - Reads `?error=oauth_unconfigured` query param to automatically trigger the PIN sign-in modal.
   - Displays "Sign in with Admin PIN" alongside "Sign in with Google", with contextual messaging when unconfigured.
6. **`web/src/features/account/AccountPage.test.tsx`**:
   - Added test verifying Admin PIN fallback and modal opening when OAuth is unconfigured (13/13 passing).

---

## 3. Verification & Test Battery
- **Rust Backend**:
  - `scripts\cargo.bat test --manifest-path rust/Cargo.toml --test auth_pin_login_test`: **3/3 passed**.
  - Full Rust test battery across all 15 test suites: **All passed**.
- **Frontend**:
  - `npm --prefix web test src/components/AdminPinSignInModal.test.tsx`: **6/6 passed**.
  - `npm --prefix web test src/features/account/AccountPage.test.tsx`: **13/13 passed**.
  - Full Vitest suite: **203/203 passed across 29 test files**.
  - TypeScript typecheck (`tsc -b`): **0 errors**.
  - Vite production build (`npm --prefix web run build`): **Clean compilation in 821ms** into `web/dist/`.
- **Android Client Probe**:
  - `scripts\probe_android_api.py`: **22/22 endpoints passed**.
