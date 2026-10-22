# Walkthrough: Admin Re-Lock Feature & Sign-Out Purge

**Date:** 2026-10-18  
**Branch:** `feat/active-transcoding-dashboard`  
**Tracking Issue:** Implement mechanism to re-lock admin mode after unlocking via PIN or Google session, and ensure signing out clears admin credentials.

---

## 1. Overview & Context

Previously, once a user unlocked administrative controls on `/manage` (via Admin PIN verification or Google Admin session), the unlocked state remained sticky in `sessionStorage` indefinitely during that browser session. Even clicking "Sign out" in the navigation bar only cleared backend authentication cookies while leaving `ms_admin_unlocked = 'true'` in `sessionStorage`. Consequently, returning to `/manage` showed the admin interface in full without re-verification.

Furthermore, there was no user-facing control to manually re-lock admin mode on `/manage` or `/devices` once unlocked.

This update introduces:
1. An interactive **"🔒 Lock Admin"** button on `/manage`.
2. A matching **"🔒 Lock Fleet"** button on `/devices`.
3. Automatic purging of all `sessionStorage` admin credentials (`ms_admin_pin`, `ms_admin_unlocked`, `ms_admin_manual_lock`) on **"Sign out"**.
4. Full integration and unit test coverage verifying immediate re-locking and gate display.

---

## 2. Key Changes Implemented

### A. Automatic Admin Token Purge on Sign-Out
- **File:** [`web/src/auth/AuthProvider.tsx`](file:///e:/MediaServer/web/src/auth/AuthProvider.tsx)
- **Change:** Updated `signOut()` to purge all admin-related keys from `sessionStorage` (`ms_admin_pin`, `ms_admin_unlocked`, `ms_admin_manual_lock`) before redirecting to `/auth/logout`.
- **Outcome:** Signing out immediately revokes both Google session cookies and client-side admin PIN tokens.

### B. Interactive Admin Re-Lock on Manage Page
- **File:** [`web/src/features/manage/ManagePage.tsx`](file:///e:/MediaServer/web/src/features/manage/ManagePage.tsx)
- **Changes:**
  - Added `isManuallyLocked` state backed by `sessionStorage.getItem('ms_admin_manual_lock') === 'true'`.
  - Refined `isAdmin` determination:
    ```tsx
    const isAdmin = !isManuallyLocked && (role === 'admin' || isPinUnlocked);
    ```
  - Implemented `handleLockAdmin`:
    ```tsx
    const handleLockAdmin = () => {
      sessionStorage.removeItem('ms_admin_pin');
      sessionStorage.removeItem('ms_admin_unlocked');
      sessionStorage.setItem('ms_admin_manual_lock', 'true');
      setAdminPin('');
      setIsPinUnlocked(false);
      setIsManuallyLocked(true);
      setSettings(null);
      setAuditData(null);
      setFeedback('Admin controls locked.');
    };
    ```
  - Added an interactive **"🔒 Lock Admin"** button alongside the `Admin Verified` status badge in the header toolbar.
  - Resetting `isManuallyLocked` to `false` whenever valid PIN verification occurs in `handleVerifyPin`.

### C. Fleet Privacy Re-Lock on Devices Page
- **File:** [`web/src/features/devices/DevicesPage.tsx`](file:///e:/MediaServer/web/src/features/devices/DevicesPage.tsx)
- **Changes:**
  - Added `handleLockFleet` to purge PIN credentials from `sessionStorage` and revert the view to privacy-scoped single-device mode.
  - Added an interactive **"🔒 Lock Fleet"** button next to the `Fleet Admin View` badge.

### D. Icons & UI Consistency
- **File:** [`web/src/components/icons.tsx`](file:///e:/MediaServer/web/src/components/icons.tsx)
- **Change:** Registered `lock` and `unlock` SVG icons in `IconName` and `PATHS` matching the obsidian design system.

---

## 3. Verification & Test Results

### A. Automated Frontend Unit & Edge Case Tests
Ran the entire frontend test suite with Vitest:
```text
✓ src/features/manage/ManagePage.test.tsx (9 tests)
    ✓ renders access-denied gate when not authenticated as admin, blocking settings & audit
    ✓ filters movies by search query and category chips
    ✓ unlocks admin mode with valid PIN and updates badge
    ✓ locks admin mode on Lock Admin click
    ✓ prompts for PIN when deleting a movie while locked
    ✓ sends X-Admin-Pin when updating storage policy
    ✓ filters by Needs Pre-Transcode chip and allows triggering pre-transcode
    ✓ triggers library scan with admin credentials and displays feedback
✓ src/features/devices/DevicesPage.test.tsx (3 tests)

Test Files: 30 passed (30)
     Tests: 214 passed (214)
  Duration: 45.54s
```

### B. Production Web Build
Executed `npm run build`:
- `tsc -b` type checking: **0 errors**.
- Vite bundling: Clean build completed in 1.94s into `web/dist/`.
- Assets served dynamically by Rust Axum static file handler.

---

## 4. How to Verify Live

1. Navigate to `/manage` in your browser.
2. If already unlocked, look at the top-right header action bar next to **"Admin Verified"** — you will see the new red **"🔒 Lock Admin"** button.
3. Click **"Lock Admin"**:
   - The Manage page immediately locks, dropping back to the `<AdminAccessGate />` view ("Administrator Authentication Required").
   - Sensitive storage policy options and audit controls are concealed.
4. Click **"Unlock with Admin PIN"** and enter `[admin-pin]`:
   - Admin controls instantly unlock.
5. Click **"Sign out"** in the top navigation bar:
   - Your session is ended and all local admin tokens are purged from `sessionStorage`. Returning to `/manage` will require re-authentication.
