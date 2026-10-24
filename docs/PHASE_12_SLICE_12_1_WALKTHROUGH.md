# Walkthrough — Phase 12 Slice 12.1: Flutter Auth Foundation & Persistent Session Infrastructure

**Phase:** Phase 12 (Mobile & TV Auth Parity & Native Admin Management)  
**Slice:** 12.1 (Authentication Foundation & Persistent Session Infrastructure)  
**Working Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Status:** ✅ COMPLETE & VERIFIED  

---

## 1. Overview & Delivered Capabilities

Slice 12.1 establishes the authentication core for the Flutter client (`in.anisparvez.media_server_client`). Prior to this slice, the Flutter client operated purely in guest mode, attaching only an ephemeral hardware device ID (`X-Device-Id`).

With Slice 12.1, the Flutter client now has:
1. **Domain Models:**
   - `UserIdentity`: Encapsulates user profile details (`id`, `email`, `name`, `pictureUrl`, `role`, `isAdmin`, `oauthConfigured`) with dedicated JSON parsers for `/api/auth/me` and `/api/auth/login-pin`.
   - `AuthState`: Immutable union state (`initial`, `authenticating`, `authenticated`, `unauthenticated`, `error`) with reactive privilege getters (`isAuthenticated`, `isAdmin`, `isGuest`).
2. **Secure Persistent Storage (`AuthSecureStorage`):**
   - Hardware-backed storage using `FlutterSecureStorage` (with AES-GCM and KeyStore RSA key wrapping on Android).
   - Manages `sessionToken`, `adminPin`, and safe wipe operations with defensive error resilience.
3. **Core API Client & Interceptor Upgrades:**
   - `DeviceAuthInterceptor`: Dynamically injects `Cookie: session_token=<stored_token>` and `X-Admin-Pin: <stored_pin>` into all outgoing Dio HTTP requests without circular dependencies.
   - Preserves existing custom cookie headers and intercepts HTTP 401 Unauthorized errors to signal session expiry.
   - `ApiEndpoints`: Registered `/api/auth/me`, `/api/auth/login-pin`, `/auth/logout`, `/api/auth/qr`, and `/api/auth/qr/lookup`.
   - `AppException`: Added `ValidationException` and `UnauthorizedException`.
4. **Remote Repository (`AuthRepository`):**
   - Coordinates `getMe()`, `loginWithPin()`, `verifyAdminPin()`, and `logout()`.
5. **Riverpod State Management (`AuthNotifier`):**
   - `authNotifierProvider`: Reactive controller exposing `hydrate()`, `loginWithPin()`, `setSessionToken()`, `verifyAndUnlockAdminPin()`, `clearAdminPin()`, and `logout()`.
   - Convenience providers: `isAuthenticatedProvider`, `isAdminProvider`, `currentUserProvider`.
   - Wired `hydrate()` into `AppShell.initState()` post-frame callback for non-blocking startup session recovery.

---

## 2. Key Code Changes

| File | Change Description |
|:---|:---|
| `flutter_client/lib/core/api/api_endpoints.dart` | Added auth and QR endpoint constants. |
| `flutter_client/lib/core/constants/storage_keys.dart` | Added `sessionToken`, `adminPin`, and `rememberAdminPin` keys. |
| `flutter_client/lib/core/errors/app_exception.dart` | Added `ValidationException` and `UnauthorizedException`. |
| `flutter_client/lib/features/auth/domain/models/user_identity.dart` | Created `UserIdentity` model with JSON deserializers. |
| `flutter_client/lib/features/auth/domain/models/auth_state.dart` | Created `AuthState` immutable state model. |
| `flutter_client/lib/features/auth/infrastructure/auth_secure_storage.dart` | Created `AuthSecureStorage` hardware-backed storage service. |
| `flutter_client/lib/core/api/api_interceptors.dart` | Updated `DeviceAuthInterceptor` to inject session cookie and admin PIN header, and trigger `onUnauthorized`. |
| `flutter_client/lib/core/api/api_client.dart` | Injected `authSecureStorageProvider` and `onUnauthorized` callback into `DeviceAuthInterceptor`. |
| `flutter_client/lib/features/auth/infrastructure/auth_repository.dart` | Created `AuthRepository` coordinating API endpoints and token persistence. |
| `flutter_client/lib/features/auth/presentation/controllers/auth_notifier.dart` | Created Riverpod `AuthNotifier` state controller. |
| `flutter_client/lib/features/auth/presentation/providers/auth_providers.dart` | Created Riverpod providers for storage, repository, notifier, and role selectors. |
| `flutter_client/lib/features/shell/presentation/screens/app_shell.dart` | Wired background `hydrate()` on app launch. |
| `flutter_client/test/features/auth/*` | Added 4 comprehensive test suites (23 unit tests). |

---

## 3. Verification & Test Evidence

### 3.1 Static Analysis Cleanliness
```bash
$ flutter analyze
Analyzing flutter_client...
No issues found! (ran in 6.8s)
```

### 3.2 Automated Auth Test Suite
```bash
$ flutter test test/features/auth/
00:00 +0: DeviceAuthInterceptor Injects Cookie and X-Admin-Pin headers when present in secure storage
00:00 +1: DeviceAuthInterceptor Preserves existing cookies when appending session_token cookie
00:00 +2: DeviceAuthInterceptor Invokes onUnauthorized callback when response status is 401
00:00 +3: AuthNotifier initial state is AuthState.initial
00:01 +4: AuthNotifier hydrate transitions to unauthenticated when storage is empty
00:01 +5: AuthNotifier hydrate restores authenticated state when valid token and identity exist
00:01 +6: AuthNotifier hydrate clears stale token when getMe returns guest
00:01 +7: AuthNotifier loginWithPin updates state to authenticated on success
00:01 +8: AuthNotifier loginWithPin handles failure cleanly
00:01 +9: AuthNotifier setSessionToken stores token and hydrates profile
00:01 +10: AuthNotifier handleUnauthorized wipes session and resets to guest
00:01 +11: AuthRepository getMe returns UserIdentity when authenticated
00:01 +12: AuthRepository getMe returns UserIdentity.guest on 401 or unauthenticated response
00:01 +13: AuthRepository loginWithPin extracts session token and saves to secure storage
00:01 +14: AuthRepository loginWithPin throws ValidationException on empty input
00:01 +15: AuthRepository loginWithPin throws UnauthorizedException on 401 response
00:01 +16: AuthRepository verifyAdminPin returns true when backend confirms
00:01 +17: AuthRepository logout calls remote endpoint and purges local secure storage
00:01 +18: AuthSecureStorage stores, retrieves, and clears session token
00:01 +19: AuthSecureStorage stores, retrieves, and clears admin pin
00:01 +20: AuthSecureStorage clearAll wipes both session token and admin pin
00:01 +23: All tests passed!
```

### 3.3 Existing Interceptor Suite Regression Test
```bash
$ flutter test test/api_interceptors_test.dart
00:00 +0: DeviceAuthInterceptor Injects X-Device-Id, User-Agent, and Accept headers into RequestOptions
00:00 +1: DeviceAuthInterceptor Maps DioException to AppException on error
00:00 +2: All tests passed!
```

### 3.4 Android API Contract Probe (Live Backend)
```bash
$ python scripts/probe_android_api.py
RESULT: all 22 Android client endpoints respond per contract
        (0 HTML pages requested - the app has no WebView, so template
         changes cannot affect it)
```

---

## 4. Next Step: Slice 12.2

With Slice 12.1 verified and green, the foundation is ready for **Slice 12.2: Mobile Phone Auth Views (Google OAuth & Admin PIN Login)**:
- In-App Custom Tabs launcher for Google OAuth via `/auth/google` with deep-link redirect (`ahms://auth/callback`).
- Interactive numeric Admin PIN bottom sheet.
- Profile & Account view in Settings with Avatar, Role badges, and Sign-In/Sign-Out controls.
