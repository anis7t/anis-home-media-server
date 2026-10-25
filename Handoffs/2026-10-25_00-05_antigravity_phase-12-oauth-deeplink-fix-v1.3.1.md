# Session Handoff: Google OAuth Deep-Link Fix & Android Release v1.3.1

**Timestamp (IST):** 2026-10-25 00:05  
**Working Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Agent:** Antigravity  

---

## 1. Executive Summary & Root Cause Analysis

During manual testing of Google OAuth sign-in on an Android mobile device connected via ADB (`192.168.1.6:40283`), the app crashed to a red screen:
```
Page Not Found
GoException: no routes for location: ahms://auth/callback?session_token=sess_...
```

### Root Cause
1. In `flutter_client/android/app/src/main/AndroidManifest.xml`, the intent filter was registered for scheme `ahms`, host `auth`, path `/callback`.
2. When Chrome Custom Tabs completed OAuth and invoked `ahms://auth/callback?session_token=...`, the Android OS dispatched an `ACTION_VIEW` intent to `MainActivity`.
3. Flutter's engine received this intent and fed the full URI `ahms://auth/callback?...` directly into the navigation system (`RouteInformationParser` / `GoRouter`).
4. `GoRouter` had no route matching `ahms://auth/callback`, no top-level URL redirect, and no `onException` handler. Consequently, GoRouter threw an unhandled `GoException`, replacing the app UI with the default red error screen.

---

## 2. Changes Made & Architecture Hardening

1. **GoRouter Deep-Link Interception (`flutter_client/lib/app/routes.dart`):**
   - Implemented a top-level `redirect` in `AppRoutes.createRouter` that catches `uri.scheme == 'ahms'`, `uri.host == 'auth'`, and callback paths.
   - Extracts `session_token` from query parameters and invokes `onTokenReceived(token)` before redirecting cleanly to `AppRoutes.settings`.
   - Added `onException` handler as a fail-safe to gracefully log any malformed URIs and route safely to Settings or Home without ever displaying an error screen.
   - Added explicit top-level routes `/auth/callback` and `/callback` as fallbacks.
   - Exposed `routerProvider` in Riverpod to prevent recreation of GoRouter across widget rebuilds.

2. **Idempotent Token Ingestion (`flutter_client/lib/features/auth/presentation/controllers/auth_notifier.dart`):**
   - Added an active token comparison guard in `setSessionToken`:
     ```dart
     if (state.sessionToken == token && state.isAuthenticated) {
       return true;
     }
     ```
   - Prevents duplicate remote `/api/auth/me` calls when both `GoRouter.redirect` and `OAuthLauncherService` / `app_links` receive the intent concurrently.

3. **Application Router Binding (`flutter_client/lib/app/app.dart`):**
   - Wired `MediaServerApp` to consume `ref.watch(routerProvider)`.

---

## 3. Verification & Testing

1. **Automated Unit & Widget Tests:**
   - Auth and Admin test suites passed: **78 / 78 tests passed** (`flutter test test/features/auth/ test/features/admin/`).
   - Verified deep-link routing specifically in `test/features/auth/deep_link_routing_test.dart` for:
     - Runtime intent delivery (`ahms://auth/callback?session_token=...`).
     - Cold-boot launch with intent URI.
     - Fallback route `/auth/callback`.
2. **Static Analysis:**
   - `flutter analyze` completed with **0 errors, 0 warnings**.
3. **Release Build & Publication:**
   - Built and published **v1.3.1 (versionCode 144)** to the production update channel via `scripts/release_android.py`.
   - Manifest updated at `updates/production/manifest.json`.
4. **Live Physical Device Verification via ADB:**
   - Installed v1.3.1 onto connected phone (`192.168.1.6:40283`).
   - Dispatched real `ahms://auth/callback?session_token=sess_...` intent via ADB `am start`.
   - Inspected `logcat` confirming:
     `[OAuthLauncherService] Captured session token from deep link!`
     with zero `GoException` and zero crashes.
   - Captured screen confirmation showing user profile **Anis Parvez** (`ADMIN`), `Admin Management UNLOCKED`, and `Version 1.3.1 (Build 144)`.
