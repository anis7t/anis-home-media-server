# Implementation Plan — Sub-item 3.1: Admin PIN Rotation

- **Date:** 2026-10-24
- **Author:** Antigravity (Advanced Agentic Pair Programmer)
- **Status:** 📋 **PENDING USER APPROVAL**
- **Target Tracking:** Category 3.1 in [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md), [`docs/Current issues.md`](Current%20issues.md)

---

## 1. Context & Background

The live `admin_pin` in the production PostgreSQL database (`media_server` table `settings`) is currently set to the bootstrap default value (`791654`). The backend already exposes `POST /api/admin/pin` (in [`rust/src/routes/admin.rs`](../rust/src/routes/admin.rs) and [`rust/src/services/auth_service.rs`](../rust/src/services/auth_service.rs)), which validates the caller's authorization (either existing valid PIN or active admin session) and updates `settings.admin_pin` with a minimum 4-digit requirement.

However:
1. The web frontend has no UI affordance to change or rotate the PIN once signed in as an administrator.
2. No administrative CLI utility exists to safely rotate the PIN out-of-band on the host.
3. The live PIN remains on the publicly known bootstrap value and needs to be rotated to a personal secret.

---

## 2. Scope

### In Scope
- **Backend API Validation:** Verify that `POST /api/admin/pin` properly validates current authorization, rejects short/invalid PINs (< 4 digits), updates the database atomically, and invalidates or updates active session PIN caching.
- **Frontend UI Affordance (Approach 1):**
  - Add `updateAdminPin({ currentPin, newPin })` in `web/src/lib/api/account.ts` (or `manage.ts`).
  - Create `<ChangeAdminPinModal.tsx>` (portaled modal with current PIN, new PIN, confirm PIN fields, inline validation, and error surfacing).
  - Add a "Change Admin PIN" button inside the Admin section on `/account` and `/manage` (visible when authorized as admin).
  - Unit tests for `<ChangeAdminPinModal>` and API helper.
- **Administrative CLI Utility:**
  - Create `scripts/rotate_admin_pin.ps1` allowing the operator on the Windows host to rotate the PIN securely from an elevated terminal.
- **Execution of Rotation:**
  - Execute the actual PIN rotation from `791654` to the owner's chosen secret PIN.
- **Verification & Documentation:**
  - Verify that the old PIN `791654` fails authorization (401) and the new PIN succeeds (200).
  - Update `docs/PROJECT_STATUS.md` and `Handoffs/`.

### Out of Scope
- Changing the Google OAuth authentication mechanism or allowlist policy.
- Modifying client presence tracking or device tokens.
- Breaking the Android/Flutter client contract (`/api/admin/verify` continues to function unchanged).

---

## 3. Implementation Steps

### Step 1: Verify & Test Backend Route (`POST /api/admin/pin`)
1. Review `admin_pin_handler` in `rust/src/routes/admin.rs` and `AuthService::update_admin_pin` in `rust/src/services/auth_service.rs`.
2. Confirm test coverage in `rust/tests/admin_test.rs` or add integration tests covering:
   - Anonymous caller without current PIN -> 403 Forbidden.
   - Caller with invalid current PIN -> 403 Forbidden.
   - Caller with valid current PIN + new PIN < 4 digits -> 400 Bad Request.
   - Caller with valid current PIN + valid new PIN -> 200 OK + database updated.

### Step 2: Implement Administrative CLI Rotation Utility (`scripts/rotate_admin_pin.ps1`)
1. Create a non-interactive/interactive PowerShell utility:
   ```powershell
   # Accepts -NewPin (or prompts securely with Read-Host -AsSecureString)
   # Verifies connection to PostgreSQL 18.4 (MediaServerPG)
   # Prompts for current PIN if configured
   # Updates settings table atomically
   ```
2. Validates clean input (digits only, length >= 4).

### Step 3: Implement Web UI Affordance for PIN Rotation
1. **API Client (`web/src/lib/api/manage.ts` or `account.ts`):**
   - Export `changeAdminPin(currentPin: string, newPin: string): Promise<{ success: boolean }>`.
2. **Component (`web/src/features/manage/components/ChangeAdminPinModal.tsx`):**
   - Follow obsidian design tokens (frosted glass, brand red accents, portaled to `document.body`).
   - Fields: Current PIN, New PIN, Confirm New PIN.
   - Guardrails: Masked numeric inputs, auto-focus, accessible ARIA labels, escape key dismissal.
3. **Integration:**
   - Mount button `Change Admin PIN` on `/account` (in Admin Card) and `/manage` (in Admin unlocked state).
4. **Automated Tests:**
   - Create `ChangeAdminPinModal.test.tsx` verifying validation, mismatch warnings, API submission, and error handling.

### Step 4: Execute Rotation to Owner's Desired PIN
1. Prompt owner for their chosen PIN (or execute via the rotation script / UI).
2. Verify live database:
   ```sql
   SELECT value FROM settings WHERE key = 'admin_pin';
   ```
3. Test authentication:
   - Old PIN `791654` -> rejected.
   - New PIN -> accepted.

### Step 5: Regression & Build Verification
1. Run `cargo test` on backend.
2. Run `npm run typecheck` and `npm run test` on web frontend.
3. Run `python scripts/probe_android_api.py` to ensure zero contract breakage.
4. Update `docs/PROJECT_STATUS.md` and write completion walkthrough.

---

## 4. Exit Criteria

- [ ] `POST /api/admin/pin` and `scripts/rotate_admin_pin.ps1` verified functional.
- [ ] Front-end provides a secure, tested `<ChangeAdminPinModal>` for administrators.
- [ ] Bootstrap default PIN `791654` is replaced in production PostgreSQL with the owner's secret PIN.
- [ ] Old PIN returns 401 Unauthorized; New PIN returns 200 OK across `/api/admin/verify`, `/manage`, `/api/scan`, and `/account`.
- [ ] All test suites green: Rust unit/integration tests, React Vitest (325+ tests), and Android API probe (22/22 endpoints).

---

## 5. Risks & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Lockout from Admin mode | Cannot delete media or manage storage | `scripts/rotate_admin_pin.ps1` connects directly via PostgreSQL superuser on localhost (`C:\postgres\pgsql\bin\psql.exe`), providing guaranteed recovery even if the current PIN is forgotten. |
| In-flight sessions invalidation | Existing browser sessions get 401 | `AuthService::is_admin_authorized` checks both session cookie and PIN; session rows for Google admins remain valid regardless of PIN changes. |
| Shoulder surfing / plaintext leak | PIN exposed | Mask input fields in UI; never log plain PIN in service logs; use secure strings in PowerShell. |

---

## 6. Open Decisions for User

1. **Rotation Interface:**
   - **Option A (Recommended):** Implement both the **Web UI modal (`<ChangeAdminPinModal>`)** and the **Host CLI utility (`scripts/rotate_admin_pin.ps1`)**, providing full administrative self-service from browser and server console.
   - **Option B (CLI Only):** Implement only the host script `scripts/rotate_admin_pin.ps1` to update the PIN directly on the database without adding new web frontend UI elements.

2. **PIN Value Delivery:**
   - The owner can enter the new PIN directly via the new UI / script, or supply the desired new PIN in a secure local prompt.
