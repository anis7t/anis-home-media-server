# Slice A Walkthrough: Dedicated App Distribution Route & Native Rust APK Streaming

**Phase:** Immediate Active Issues (Issue 1 of 4)  
**Branch:** `feat/phase-9-pre-transcode-capabilities` (`6ba1e3a`)  
**Status:** COMPLETE & VERIFIED  
**Date:** 2026-10-18  

---

## 1. Summary of Changes

Slice A resolves the `404 Not Found` error when users click "Get the app" or visit `/download`. It delivers a dedicated, obsidian-glass APK distribution page and ports the app update and APK streaming endpoints natively to Rust with RFC 7233 byte-range support.

### Key Deliverables:

1. **Native Rust APK Serving & Updates ([`rust/src/routes/app_dist.rs`](file:///E:/MediaServer/rust/src/routes/app_dist.rs)):**
   - Implemented `GET /api/app/download?channel=production`:
     - Resolves `updates/{channel}/media-server-client.apk` (102 MB).
     - Full support for RFC 7233 byte ranges via `RangeService::stream_file`: answers `206 Partial Content` with `Content-Range: bytes START-END/TOTAL` for chunked, resumable downloads.
     - Attachment headers: `Content-Disposition: attachment; filename="media-server-{channel}.apk"` and `Content-Type: application/vnd.android.package-archive`.
   - Implemented `GET /api/app/update?channel=production`:
     - Reads `updates/{channel}/manifest.json` and returns version information with `Cache-Control: no-cache, no-store, must-revalidate`.
   - Registered endpoints under Axum in [`rust/src/lib.rs`](file:///E:/MediaServer/rust/src/lib.rs).

2. **React Download Page ([`web/src/features/download/DownloadPage.tsx`](file:///E:/MediaServer/web/src/features/download/DownloadPage.tsx)):**
   - High-contrast obsidian glass card layout with brand-red gradients.
   - **Card 1: Android Phones & Tablets**:
     - Version pill `v1.2.20` & size `97.5 MB`.
     - Direct download action button linking to `/api/app/download?channel=production`.
     - Developer channel fallback link (`?channel=developer`).
   - **Card 2: Amazon Fire TV & Android TV**:
     - Sideloading instructions using the orange **Downloader** app on Fire TV.
     - Code block showing the direct server endpoint.
   - **Card 3: Cryptographic Verification**:
     - Display and 1-click copy button for the SHA-256 fingerprint:
       `7bc4e2716e0f753bf4ca7a142b4a20d69cb7057c3717d10bb42ca052eda168f2`.

3. **Routing & Navigation Integration:**
   - In [`web/src/main.tsx`](file:///E:/MediaServer/web/src/main.tsx), mapped `/download`, `/app`, and `/android` to `<DownloadPage />`.
   - In [`web/src/app/AppShell.tsx`](file:///E:/MediaServer/web/src/app/AppShell.tsx) and [`web/src/features/manual/ManualPage.tsx`](file:///E:/MediaServer/web/src/features/manual/ManualPage.tsx), replaced raw `<a>` tags with React Router `<NavLink to="/download">` and `<Link to="/download">` for instant client-side transitions.

---

## 2. Verification & Test Outcomes

### 1. Rust Integration Tests ([`rust/tests/app_dist_test.rs`](file:///E:/MediaServer/rust/tests/app_dist_test.rs))
```text
running 5 tests
test test_app_update_invalid_channel ... ok
test test_app_download_invalid_channel ... ok
test test_app_update_production_manifest ... ok
test test_app_download_production_full_apk ... ok
test test_app_download_production_range_request ... ok

test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.51s
```
- Full Rust test suite: **116/116 passed across all 14 integration test suites**.

### 2. Frontend Vitest Tests ([`web/src/features/download/DownloadPage.test.tsx`](file:///E:/MediaServer/web/src/features/download/DownloadPage.test.tsx))
```text
 ✓ src/features/download/DownloadPage.test.tsx (2 tests) 325ms

Test Files  28 passed (28)
     Tests  196 passed (196)
```
- TypeScript check: `tsc -b` passed with **0 errors**.
- Production build: `npm run build` compiled clean into `web/dist` in **935ms**.

### 3. Client Contract Probe ([`scripts/probe_android_api.py`](file:///E:/MediaServer/scripts/probe_android_api.py))
```text
RESULT: all 22 Android client endpoints respond per contract
        (0 HTML pages requested - the app has no WebView, so template
         changes cannot affect it)
```

---

## 3. Next Slices

- **Slice B**: Google Sign-in 503 resolution & Local Admin PIN sign-in fallback.
- **Slice C**: Subtitle delay (+ / -) flicker fix via cue timestamp shifting.
- **Slice D**: Chrome native 4K HEVC / H.265 detection and Direct Play unlock.
