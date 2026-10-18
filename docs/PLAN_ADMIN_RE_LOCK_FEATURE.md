# Implementation Plan: Admin Re-Lock Feature & Sign-Out Purge

**Date:** 2026-10-18  
**Branch:** `feat/active-transcoding-dashboard`  
**Tracking Issue:** No mechanism to re-lock admin mode after unlocking via PIN or Google session  

---

## 1. Problem Statement & User Need

Currently:
1. When a user unlocks the Manage page via Admin PIN (`verifyAdminPin`), `sessionStorage` persists:
   ```ts
   sessionStorage.setItem('ms_admin_pin', candidatePin);
   sessionStorage.setItem('ms_admin_unlocked', 'true');
   ```
   And `isPinUnlocked` is set to `true`.
2. On [`ManagePage.tsx`](file:///e:/MediaServer/web/src/features/manage/ManagePage.tsx#L383-L389), the UI renders a static, non-interactive `<span>Admin Verified</span>` badge. There is no button, trigger, or mechanism to re-lock admin controls.
3. On [`DevicesPage.tsx`](file:///e:/MediaServer/web/src/features/devices/DevicesPage.tsx#L106-L108), unlocking the fleet IP telemetry also writes to `sessionStorage` without an explicit re-lock action.
4. When a user clicks **"Sign out"** in the navigation header, [`AuthProvider.tsx`](file:///e:/MediaServer/web/src/auth/AuthProvider.tsx#L92) redirects to `/auth/logout`, clearing server-side session cookies, but **does not clear `sessionStorage`**. Consequently, returning to `/manage` finds `ms_admin_unlocked: 'true'` and keeps the client unlocked with admin privileges even in a signed-out state.

---

## 2. Scope

### In Scope
1. **Interactive "🔒 Lock Admin" Action on `/manage`:**
   - In [`ManagePage.tsx`](file:///e:/MediaServer/web/src/features/manage/ManagePage.tsx), replace the static `Admin Verified` badge with a combined status badge + interactive **"🔒 Lock Admin"** button.
   - Clicking "Lock Admin":
     - Clears `ms_admin_pin` and `ms_admin_unlocked` from `sessionStorage`.
     - Sets a session-scoped `ms_admin_manual_lock = 'true'` flag so that even if signed in via Google, the Manage page immediately locks and displays `<AdminAccessGate />`.
     - Resets local state (`setIsPinUnlocked(false)`, `setAdminPin('')`, `setIsManuallyLocked(true)`).
     - Renders `<AdminAccessGate />` immediately, requiring PIN verification or manual unlock to re-enter.
2. **Automatic Session Storage Purge on Sign Out:**
   - In [`web/src/auth/AuthProvider.tsx`](file:///e:/MediaServer/web/src/auth/AuthProvider.tsx), update `signOut()` to purge all admin session keys (`ms_admin_pin`, `ms_admin_unlocked`, `ms_admin_manual_lock`) before redirecting to `/auth/logout`.
3. **Interactive "🔒 Lock Fleet" Action on `/devices`:**
   - In [`DevicesPage.tsx`](file:///e:/MediaServer/web/src/features/devices/DevicesPage.tsx), when fleet privacy is unlocked, provide a matching **"🔒 Lock Fleet"** action that clears `ms_admin_unlocked` and returns the view to the privacy-scoped single device state.
4. **Automated Frontend Tests:**
   - Update `ManagePage.test.tsx` and `DevicesPage.test.tsx` to assert that clicking "Lock Admin" and "Lock Fleet" properly purges session storage and displays the locked gate.

### Deliberately Out of Scope
- Backend database schema changes (this is purely clientside state & session lifecycle management).
- Altering Android TV pairing tokens.

---

## 3. Exit Criteria
1. On `/manage`, an unlocked user sees an interactive **"🔒 Lock Admin"** button.
2. Clicking **"Lock Admin"** immediately transitions `/manage` back to the locked `<AdminAccessGate />` state and removes PIN tokens from `sessionStorage`.
3. Unlocking again with PIN `6361` successfully restores full administrative access.
4. Clicking **"Sign out"** from anywhere in the app completely clears all `sessionStorage` admin tokens so a signed-out client is never auto-unlocked.
5. On `/devices`, unlocking fleet telemetry shows a **"🔒 Lock Fleet"** button that re-engages privacy scoping upon click.
6. All existing React component unit tests pass cleanly.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Google session vs Manual Lock conflict** | User signed in with Google Admin might instantly bypass manual lock on reload | When `ms_admin_manual_lock === 'true'`, `ManagePage` explicitly respects the manual lock over the Google `role === 'admin'` until unlocked via PIN or clear. |
| **Component state desync** | Re-locking in one tab doesn't notify other tabs | `sessionStorage` is tab-isolated by design, matching browser security sandboxing. |

---

## 5. Implementation Steps

1. **Update [`web/src/auth/AuthProvider.tsx`](file:///e:/MediaServer/web/src/auth/AuthProvider.tsx):**
   - In `signOut()`, clear `ms_admin_pin`, `ms_admin_unlocked`, and `ms_admin_manual_lock` from `sessionStorage` before navigating to `/auth/logout`.
2. **Update [`web/src/features/manage/ManagePage.tsx`](file:///e:/MediaServer/web/src/features/manage/ManagePage.tsx):**
   - Add `isManuallyLocked` state backed by `sessionStorage.getItem('ms_admin_manual_lock') === 'true'`.
   - Update `isAdmin` logic: `const isAdmin = !isManuallyLocked && (role === 'admin' || isPinUnlocked);`.
   - In `handleVerifyPin`, clear `sessionStorage.removeItem('ms_admin_manual_lock')` and set `setIsManuallyLocked(false)`.
   - Implement `handleLockAdmin`:
     ```ts
     const handleLockAdmin = () => {
       sessionStorage.removeItem('ms_admin_pin');
       sessionStorage.removeItem('ms_admin_unlocked');
       sessionStorage.setItem('ms_admin_manual_lock', 'true');
       setAdminPin('');
       setIsPinUnlocked(false);
       setIsManuallyLocked(true);
       setFeedback('Admin controls locked.');
     };
     ```
   - Render the `Lock Admin` button in the header toolbar when `isAdmin` is true.
3. **Update [`web/src/features/devices/DevicesPage.tsx`](file:///e:/MediaServer/web/src/features/devices/DevicesPage.tsx):**
   - Add `handleLockFleet` that clears `sessionStorage.removeItem('ms_admin_pin')`, `sessionStorage.removeItem('ms_admin_unlocked')`, sets `setIsFleetUnlocked(false)`, and re-scopes telemetry.
   - Render `Lock Fleet` button next to the fleet status.
4. **Run Unit Tests & Build Web App:**
   - Run `npm test -- --run` in `web/` to verify tests pass.
   - Run `npm run build` in `web/` to compile the updated bundle into `web/dist/`.
5. **Verify Live in Browser:**
   - Test unlocking `/manage` with PIN `6361`, then clicking "Lock Admin".
   - Test signing out and confirming admin is locked.
