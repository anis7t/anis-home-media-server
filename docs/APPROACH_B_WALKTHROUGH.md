# Walkthrough — Approach B: Isolating Manual Library Scan to `/manage`

## 1. Problem Statement & Motivation
- Historically, the `Scan` button was rendered globally in the consumer header ([`AppShell.tsx`](file:///e:/MediaServer/web/src/app/AppShell.tsx)) for all visitors, including unauthenticated/non-admin users.
- When `POST /api/scan` was hardened to require `X-Admin-Pin`, clicking the header button dispatched unauthenticated requests, triggering an immediate `403 Forbidden` (`Scan failed`).
- Since background ingestion runs automatically (every 1 hour via native daemon) and upon uploads, exposing a manual scan trigger to regular consumers was redundant and misleading.
- **Approach B** permanently eliminates the Scan trigger from the public consumer header and isolates manual scanning to the authenticated [`/manage`](file:///e:/MediaServer/web/src/features/manage/ManagePage.tsx) dashboard where all administrative operations reside.

---

## 2. Key Changes Delivered

### A. Web Frontend Header Clean-Up ([`web/src/app/AppShell.tsx`](file:///e:/MediaServer/web/src/app/AppShell.tsx))
- **Removed navbar scan button**: Deleted lines 149–167 rendering the spinning button.
- **Removed scan state and handlers**: Deleted `scanning`, `scanStatus`, and `onScan()` which previously sent unauthenticated POST requests.
- **Clean Consumer Navbar**: Header now exclusively shows brand navigation, library link, and client APK download pill.

### B. Admin Dashboard Hardening ([`web/src/features/manage/ManagePage.tsx`](file:///e:/MediaServer/web/src/features/manage/ManagePage.tsx), [`web/src/lib/api/manage.ts`](file:///e:/MediaServer/web/src/lib/api/manage.ts))
- **`triggerLibraryScan()` response extraction**: Harmonized to safely evaluate `success: true` from either `{ success: true }` or legacy status `{ status: "scanning" }`.
- **Admin PIN propagation**: Guaranteed `X-Admin-Pin` header is attached from session storage upon manual click.
- **Visual feedback**: Displays immediate spinning feedback (`Scanning…`), emits a green toast notification (`"Library scan started! Refreshing files and metadata..."`), and reloads library inventory after 3 seconds.

### C. Rust API Harmonization ([`rust/src/routes/scan.rs`](file:///e:/MediaServer/rust/src/routes/scan.rs))
- Updated `post_scan_handler` to explicitly return `"success": true` in the JSON response payload.
- Updated `rust/tests/scan_test.rs` to assert `"success": true`.

---

## 3. Verification & Validation Results

### 1. React Vitest Suite
```
 ✓ src/features/manage/ManagePage.test.tsx (8 tests) 2769ms
     ✓ renders access-denied gate when not authenticated as admin
     ✓ filters movies by search query and category chips
     ✓ unlocks admin mode with valid PIN and updates badge
     ✓ prompts for PIN when deleting a movie while locked
     ✓ filters by Needs Pre-Transcode chip and allows triggering pre-transcode
     ✓ triggers library scan with admin credentials and displays feedback

 Test Files  1 passed (1)
      Tests  8 passed (8)
```

### 2. React Production Build
```
✓ 104 modules transformed.
dist/index.html                    0.47 kB │ gzip:   0.30 kB
dist/assets/index-V5CbcL_P.css   127.94 kB │ gzip:  19.79 kB
dist/assets/browser-Dhwxj-Ho.js   23.46 kB │ gzip:   8.85 kB
dist/assets/index-CY23UrRJ.js    542.23 kB │ gzip: 149.40 kB
dist/assets/hls-BMtioDMk.js      574.41 kB │ gzip: 178.97 kB
✓ built in 1.90s
```

### 3. Rust Integration Tests
```
running 5 tests
test test_post_scan_with_valid_body_pin_succeeds ... ok
test test_post_scan_with_valid_header_pin_succeeds ... ok
test test_post_scan_without_admin_pin_returns_403 ... ok
test test_post_scan_rejects_query_string_pin ... ok
test test_get_scan_returns_ok_status ... ok

test result: ok. 5 passed; 0 failed
```

### 4. Release Binary Artifact Verification
- **Binary**: `rust\target\release\media-server-api.exe`
- **Binary LastWriteTime**: `2026-10-18 14:39:52`
- **Latest Commit**: `b361b6d` (`2026-10-18 14:37:45`)
- **Criterion**: Binary is strictly newer than the latest commit.

---

## 4. Next Step: Restart Persistent Service
To run the freshly compiled binary with these API and UI updates, please restart `MediaServerRust`:
```cmd
e:\MediaServer\scripts\restart_rust_service.bat
```
*(or run `Restart-Service MediaServerRust` in an elevated PowerShell terminal)*.
