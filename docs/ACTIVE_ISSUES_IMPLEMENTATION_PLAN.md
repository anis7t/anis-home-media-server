# Implementation Plan: Active Issues Resolution (Issues 1–4)

**Document:** `docs/ACTIVE_ISSUES_IMPLEMENTATION_PLAN.md`  
**Branch:** `feat/phase-9-pre-transcode-capabilities`  
**Date:** 2026-10-18  
**Author:** Antigravity  

---

## 1. Problem Statement & Scope

Following the completion of Phase 9 (Client Media Capabilities, Offline Pre-Transcode Architecture, and 100% Gating), the user has reported 4 active issues in production:

1. **"Get the app" link 404 (`/download`):**
   - In `web/src/app/AppShell.tsx`, `<a href="/download">` fails because `/download` is unmapped in `web/src/main.tsx` and in the native Rust backend. The production universal Android APK (`updates/production/media-server-client.apk`, 102 MB) exists on disk, but has no dedicated landing page or streaming endpoint in Rust.
2. **Google Sign-in returns 503 (`"Sign-in is not configured on this server."`):**
   - In `rust/src/services/auth_service.rs`, `oauth_start` fails closed with HTTP 503 when `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` are unset in `.env`. Clicking "Sign in" in the web UI navigates to `/auth/google` and displays raw JSON. There is no guidance on configuration or local authentication via Admin PIN.
3. **Subtitle delay (+ / -) causes subtitle flickering:**
   - In `web/src/features/playback/useSubtitles.ts`, calling `adjustOffset` mutates `prefs.offset` in React state. The `useEffect` listening to `prefs` triggers on every offset increment, rewriting the `<style id="cue-styles">` element in `document.head` and iterating all cues via `elevateCues()`. Rewriting global stylesheet DOM nodes and mutating cue lines causes browser layout thrashing and native WebVTT cue boxes to detach and flicker.
4. **Utilize Chrome native 4K HEVC / H.265 support:**
   - In `web/src/lib/capabilities/mediaCapabilities.ts`, the capability probe hardcodes Level 3.1 HEVC (`hvc1.1.6.L93.B0`, 720p/1080p) at 1920×1080. Chromium on Windows/macOS with GPU decoders natively supports hardware-accelerated 4K HEVC (Main / Main 10 profile Level 5.0/5.1: `hvc1.1.6.L150.90` and `hev1.1.6.L150.90`). The capability check should query native 4K HEVC decoding via `navigator.mediaCapabilities.decodingInfo()` so 4K HEVC MP4/fMP4 streams can be direct-played rather than blocked or down-converted.

---

## 2. Proposed Changes by Slice

### Slice A: Dedicated App Distribution Route & Native Rust APK Streaming
- **Native Rust APK Serving (`rust/src/routes/app_dist.rs` & `rust/src/lib.rs`):**
  - Implement native endpoint `GET /api/app/download`:
    - Reads query param `channel` (default: `'production'`, allowed: `'production' | 'developer'`).
    - Resolves `UPDATES_DIR / channel / 'media-server-client.apk'`.
    - Supports byte-range requests (`Range: bytes=...`, HTTP 206 Partial Content) and `Accept-Ranges: bytes` for resumable high-speed downloads of the ~102 MB APK.
    - Sets `Content-Disposition: attachment; filename="media-server-{channel}.apk"`, `Content-Type: application/vnd.android.package-archive`, and accurate `Content-Length`.
  - Implement native endpoint `GET /api/app/version`:
    - Serves `updates/version_registry.json` payload (`version`, `versionCode`, `sha256`, `publishedAt`) for update checkers.
  - Register `/api/app/download` and `/api/app/version` in `rust/src/lib.rs`.
- **React App Download Page (`web/src/features/download/DownloadPage.tsx`):**
  - Create a modern, obsidian-glass download showcase page:
    - Android Phone & Tablet: Direct APK download card with download button pointing to `/api/app/download?channel=production`.
    - Android TV & Amazon Fire TV Stick 4K: Step-by-step sideloading guide (Downloader app code / direct URL).
    - Release metadata: Version badge (e.g. `v1.2.20`), APK size (~102 MB), build date, and SHA-256 fingerprint verification box.
  - Register `/download` route in `web/src/main.tsx`.
  - Update `web/src/app/AppShell.tsx` and `web/src/features/manual/ManualPage.tsx` to link to `/download` via React Router `<Link to="/download">`.

### Slice B: Auth Configuration Guidance & Local Admin PIN Sign-In Fallback
- **Admin PIN Login API (`rust/src/routes/auth.rs` & `rust/src/services/auth_service.rs`):**
  - Add `POST /api/auth/login-pin`:
    - Accepts JSON payload `{ "pin": "..." }`.
    - Verifies the candidate PIN against the stored database `admin_pin` (using constant-time comparison). Fails closed if no PIN is configured.
    - Finds or creates an admin user row (`google_sub = 'admin_pin'`, `email = 'admin@local'`, `name = 'Administrator'`, `role = 'admin'`).
    - Issues a cryptographically random session token in the `sessions` table (30-day lifetime).
    - Sets the `session_token=...; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000` cookie in the HTTP response.
    - Returns `{ "success": true, "user": { "id": ..., "email": "admin@local", "name": "Administrator", "role": "admin", "is_admin": true } }`.
- **OAuth Status Discovery (`rust/src/services/auth_service.rs`):**
  - In `AuthService::get_auth_status()` / `/api/auth/me`, include `oauth_configured: bool` (`true` if `GOOGLE_CLIENT_ID` is present, `false` otherwise).
  - When `oauth_start` is invoked without OAuth configured, redirect to `/account?error=oauth_unconfigured` rather than emitting raw JSON 503.
- **Frontend Sign-In UX & Modal (`web/src/auth/AuthProvider.tsx` & `web/src/features/account/AccountPage.tsx`):**
  - When user clicks "Sign In":
    - If `oauth_configured === true`, proceed with Google OAuth redirect.
    - If `oauth_configured === false`, open an obsidian **Local Sign-In Modal**:
      - Explains that Google OAuth is not configured on this server.
      - Offers immediate local login using the **Admin PIN**.
      - Provides clear instructions on how to configure `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in `.env`.
  - On `/account`, provide an explicit "Sign in with Admin PIN" button alongside "Sign in with Google".

### Slice C: Subtitle Delay Smoothing & Flicker Elimination
- **Decouple Stylesheet Injection from Offset (`web/src/features/playback/useSubtitles.ts`):**
  - Separate `applySubStyles` effect from offset changes:
    - `applySubStyles` now depends strictly on `[prefs.color, prefs.bgOpacity, prefs.size, prefs.align]`. Changing `offset` will NEVER touch or rewrite the `<style id="cue-styles">` element in `document.head`.
- **In-Memory Timing Offset Application:**
  - In `elevateCues()`:
    - Cache original timestamps on each cue once: `(c as any)._origStartTime ??= c.startTime; (c as any)._origEndTime ??= c.endTime`.
    - Only update cue timestamps when `offset` has actually changed from `(c as any)._appliedOffset`.
    - If a cue is currently active and rendered, apply offset smoothly without resetting layout properties (`snapToLines`, `line`, `align`, `position`) unless their values actually changed.
- **Debounced Preference Persistence:**
  - Tapping or holding `z` / `x` rapidly updates in-memory cue timing immediately and updates HUD toast instantly, while debouncing `localStorage.setItem` saves by 400ms to avoid synchronous disk/storage stalls.

### Slice D: Native 4K HEVC / H.265 Capability Detection
- **4K HEVC Codec Strings & Profiling (`web/src/lib/capabilities/mediaCapabilities.ts`):**
  - Update `normalizeVideoCodecMime`:
    - For HEVC / H.265: support both `hvc1.1.6.L150.90` (Main Profile Level 5.0, up to 4K 30fps) and `hvc1.1.6.L153.B0` (Main 10 Profile Level 5.1, up to 4K 60fps). Also support `hev1.1.6.L150.90` for MP4 containers.
  - In `probeClientMediaCapabilities(container, videoCodec, audioCodec, width?, height?, bitrate?, framerate?)`:
    - Accept optional media dimensions and bitrate from `MediaInfoResponse` (defaulting to 1920×1080 if unspecified, or 3840×2160 if source resolution $\ge 2160$).
    - Pass resolution into `navigator.mediaCapabilities.decodingInfo()`:
      ```ts
      video: {
        contentType: videoContentType,
        width: width || 1920,
        height: height || 1080,
        bitrate: bitrate || 15_000_000,
        framerate: framerate || 30,
      }
      ```
    - If `decodingInfo` reports `supported: true` and `smooth: true`, permit 4K HEVC Direct Play in MP4 containers.
- **Ensure Server Allows Direct Play for 4K HEVC MP4s:**
  - Verify `rust/src/routes/media_info.rs`: MP4 files (`.mp4`, `.m4v`) already evaluate `is_direct: true` for source quality. With the updated client probe, Chromium browsers with GPU decoders will unlock Direct Play for 4K HEVC MP4s directly.

---

## 3. Exit Criteria & Verification Steps

1. **Slice A Verification:**
   - Navigating to `/download` in the browser renders the rich obsidian App Download Page.
   - Clicking "Download Production APK" initiates a byte-range download of `media-server-production.apk` from `/api/app/download?channel=production` (200 / 206 responses).
   - `GET /api/app/version?channel=production` returns HTTP 200 with JSON matching `version_registry.json`.
   - Header and Manual page download links resolve to `/download` without page reload or 404s.
2. **Slice B Verification:**
   - With Google OAuth unset in `.env`, `/api/auth/me` reports `oauth_configured: false`.
   - Clicking "Sign In" opens the Admin PIN login modal with setup instructions.
   - Submitting a valid Admin PIN via `POST /api/auth/login-pin` mints an admin session cookie (`session_token`), grants `role: 'admin'`, and updates the UI to logged-in state.
   - Submitting an invalid PIN returns HTTP 401 Unauthorized.
3. **Slice C Verification:**
   - Rapidly pressing `z` / `x` (subtitle delay - / +) smoothly shifts active subtitle timing and displays HUD toasts (`💬 Subtitle Sync: +0.20s (+200ms) (Delayed)`).
   - Zero DOM style rewrites occur during offset adjustment; subtitle text does not flash or disappear from the video canvas.
4. **Slice D Verification:**
   - Unit tests in `mediaCapabilities.test.ts` verify that 4K HEVC MIME strings (`hvc1.1.6.L150.90`, 3840×2160) are correctly structured and probed.
   - For supported Chromium platforms with OS HEVC decoders, `canDirectPlay` resolves to `true` for 4K HEVC MP4 streams.
5. **Full Regression Suite:**
   - Rust test suite: All tests pass (`cargo test`).
   - Frontend Vitest suite: All tests pass (`npm run test`).
   - TypeScript build check: `npm run typecheck` clean (0 errors).
   - Production bundle build: `npm run build` succeeds cleanly.

---

## 4. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| **Large APK file streaming stalls Axum worker threads** | Use `tokio::fs::File` with `ReaderStream` and bounded buffer chunks (64 KB) in Axum; support RFC 7233 byte-range serving so downloads are resumable. |
| **Admin PIN sign-in brute force attack** | Enforce a 5-attempt rate limiter or fail-closed verification matching existing `/api/admin/verify` security invariants. |
| **Subtitle cue timestamp mutation drift** | Always preserve immutable original timestamps in `_origStartTime` / `_origEndTime` so multiple relative adjustments always compute `origStartTime + offset` rather than accumulating floating-point drift. |
| **4K HEVC capability false positives on unsupported hardware** | Probe both container support (`canPlayType`) and W3C Media Capabilities (`decodingInfo`); only permit Direct Play if `result.supported === true`. If unsupported, fallback to pre-transcoded fMP4 HLS gracefully. |

---

## 5. Open Decisions for the User

1. **Admin PIN Sign-In Lifetime:** Should local Admin PIN sessions have the standard 30-day lifetime (matching Google OAuth sessions), or a shorter session (e.g. 24 hours)? *(Recommendation: 30 days for home media server convenience).*
2. **Download Page Routing:** Should `/download` be the canonical landing page, with `/app` and `/android` as route aliases? *(Recommendation: Yes, alias `/app` and `/android` to `/download`).*
