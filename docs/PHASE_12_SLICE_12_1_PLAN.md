# Implementation Plan — Phase 12 Slice 12.1: Flutter Auth Foundation & Persistent Session Infrastructure

**Phase:** Phase 12 (Mobile & TV Auth Parity & Native Admin Management)  
**Slice:** 12.1 (Authentication Foundation & Persistent Session Infrastructure)  
**Status:** Pending User Approval  
**Working Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Targets:** `flutter_client/lib/features/auth/`, `flutter_client/lib/core/api/`, `flutter_client/test/features/auth/`

---

## 1. Executive Summary & Purpose

Slice 12.1 establishes the production-grade authentication core for the Flutter client (`in.anisparvez.media_server_client`). Prior to this slice, the Flutter client operated purely in guest mode, attaching only an ephemeral hardware device ID (`X-Device-Id: dev_<hex>`).

This slice introduces:
1. Domain models (`UserIdentity`, `AuthSession`, `AuthState`, `AuthRole`).
2. Hardware-backed secure persistence via `flutter_secure_storage`.
3. An `AuthRepository` client calling backend endpoints `GET /api/auth/me`, `POST /api/auth/login-pin`, and `POST /auth/logout`.
4. Enhancement of `DeviceAuthInterceptor` to inject `Cookie: session_token=<token>` and `X-Admin-Pin: <pin>` across all Dio requests.
5. Riverpod `authNotifierProvider` for app-wide reactive session state and automatic startup hydration.
6. A comprehensive unit and mock test suite.

---

## 2. Scope

### In-Scope (What Changes)
- **Domain Layer (`flutter_client/lib/features/auth/domain/`):**
  - `models/user_identity.dart`: Structured representation of the authenticated user (`id`, `email`, `name`, `pictureUrl`, `role`, `isAdmin`, `oauthConfigured`).
  - `models/auth_state.dart`: Sealed/immutable state union representing (`initial`, `unauthenticated`, `authenticating`, `authenticated`, `error`).
- **Infrastructure Layer (`flutter_client/lib/features/auth/infrastructure/`):**
  - `auth_secure_storage.dart`: Hardware-backed secure storage using `FlutterSecureStorage` (with Android `EncryptedSharedPreferences` options). Safely stores `session_token`, cached `user_profile`, and optional remembered `admin_pin`.
  - `auth_repository.dart`: Communicates with Axum backend:
    - `getMe()`: Hydrates user identity from `GET /api/auth/me`.
    - `loginWithPin(String pin)`: Authenticates against `POST /api/auth/login-pin`.
    - `logout()`: Clears remote session via `POST /auth/logout`.
- **Core API Layer (`flutter_client/lib/core/api/`):**
  - `api_interceptors.dart`: Update `DeviceAuthInterceptor` to read active token from `AuthSecureStorage` and inject `Cookie: session_token=<token>` and `X-Admin-Pin: <pin>`.
  - Handle 401 response status to notify auth state of remote revocation.
  - `api_endpoints.dart`: Add `authMe = '/api/auth/me'`, `loginPin = '/api/auth/login-pin'`, and `logout = '/auth/logout'`.
- **Presentation / State Management Layer (`flutter_client/lib/features/auth/presentation/`):**
  - `controllers/auth_notifier.dart`: `AsyncNotifier<AuthState>` handling `hydrate()`, `loginWithPin()`, `setSessionToken()`, `logout()`, `verifyAdminPin()`.
  - `providers/auth_providers.dart`: Dependency injection providers for storage, repository, notifier, and convenience selectors (`isAuthenticatedProvider`, `isAdminProvider`, `currentUserProvider`).
- **App Lifecycle Integration:**
  - Wire `hydrate()` into app initialization sequence in `lib/features/shell/presentation/screens/app_shell.dart` or `lib/main.dart`.
- **Test Suites (`flutter_client/test/features/auth/`):**
  - `auth_secure_storage_test.dart`: Unit tests for secure token storage, read, write, and wipe.
  - `auth_repository_test.dart`: Mock API test for `GET /api/auth/me`, `loginWithPin`, and `logout`.
  - `auth_notifier_test.dart`: State transition test (initial -> hydrating -> authenticated / unauthenticated).
  - `api_interceptors_auth_test.dart`: Verification of `Cookie` and `X-Admin-Pin` header attachment.

### Out-of-Scope (Deliberately Deferred to Subsequent Slices)
- Mobile Google OAuth webview/CustomTab launcher and deep link callback (`Slice 12.2`).
- Mobile UI bottom sheets for PIN entry and Account Profile view (`Slice 12.2`).
- Android TV QR code pairing screen, SSE polling daemon, and on-screen D-pad keypad (`Slice 12.3`).
- Admin management views in Settings (Storage, Transcode dashboard, Devices, Audit logs) (`Slice 12.4`).
- Any changes to existing `/api/*` contracts or backend Rust database schemas (backend already supports session cookies and PIN login).

---

## 3. Detailed Technical Design

### 3.1 Data Models

```dart
// lib/features/auth/domain/models/user_identity.dart
class UserIdentity {
  final int id;
  final String email;
  final String? name;
  final String? pictureUrl;
  final String role; // 'admin' | 'viewer'
  final bool isAdmin;
  final bool oauthConfigured;

  const UserIdentity({
    required this.id,
    required this.email,
    this.name,
    this.pictureUrl,
    required this.role,
    required this.isAdmin,
    required this.oauthConfigured,
  });

  factory UserIdentity.fromJson(Map<String, dynamic> json) { ... }
  Map<String, dynamic> toJson() { ... }
}

// lib/features/auth/domain/models/auth_state.dart
enum AuthStatus { initial, authenticating, authenticated, unauthenticated, error }

class AuthState {
  final AuthStatus status;
  final UserIdentity? identity;
  final String? sessionToken;
  final String? activeAdminPin;
  final String? errorMessage;

  const AuthState({
    required this.status,
    this.identity,
    this.sessionToken,
    this.activeAdminPin,
    this.errorMessage,
  });

  bool get isAuthenticated => status == AuthStatus.authenticated && identity != null;
  bool get isAdmin => identity?.isAdmin ?? (activeAdminPin != null && activeAdminPin!.isNotEmpty);
  ...
}
```

### 3.2 Secure Storage Architecture

```dart
// lib/features/auth/infrastructure/auth_secure_storage.dart
class AuthSecureStorage {
  final FlutterSecureStorage _storage;

  static const _kSessionToken = 'auth_session_token';
  static const _kAdminPin = 'auth_admin_pin';

  Future<String?> getSessionToken() async { ... }
  Future<void> saveSessionToken(String token) async { ... }
  Future<void> clearSessionToken() async { ... }

  Future<String?> getAdminPin() async { ... }
  Future<void> saveAdminPin(String pin) async { ... }
  Future<void> clearAdminPin() async { ... }

  Future<void> clearAll() async { ... }
}
```

### 3.3 Interceptor Token Attachment & Decoupling

To prevent circular dependency (`ApiClient` -> `DeviceAuthInterceptor` -> `AuthRepository` -> `ApiClient`), `DeviceAuthInterceptor` interacts directly with `AuthSecureStorage`:

```dart
// In DeviceAuthInterceptor.onRequest:
final token = await _secureStorage.getSessionToken();
if (token != null && token.isNotEmpty) {
  // Inject session cookie recognized by Axum AuthService::resolve_session_identity
  final existingCookie = options.headers['Cookie'] as String?;
  final sessionCookie = 'session_token=$token';
  options.headers['Cookie'] = existingCookie != null && existingCookie.isNotEmpty
      ? '$existingCookie; $sessionCookie'
      : sessionCookie;
}

final adminPin = await _secureStorage.getAdminPin();
if (adminPin != null && adminPin.isNotEmpty) {
  options.headers['X-Admin-Pin'] = adminPin;
}
```

---

## 4. Step-by-Step Implementation Sequence

1. **Step 1: Endpoints & Storage Keys Configuration**
   - In `flutter_client/lib/core/api/api_endpoints.dart`, add `authMe`, `loginPin`, `logout`.
   - In `flutter_client/lib/core/constants/storage_keys.dart`, add auth storage constants.
2. **Step 2: Domain Models Implementation**
   - Create `flutter_client/lib/features/auth/domain/models/user_identity.dart`.
   - Create `flutter_client/lib/features/auth/domain/models/auth_state.dart`.
3. **Step 3: Secure Storage Implementation**
   - Create `flutter_client/lib/features/auth/infrastructure/auth_secure_storage.dart`.
   - Configure Android `AndroidOptions(encryptedSharedPreferences: true)`.
4. **Step 4: Interceptor Enhancement**
   - Update `DeviceAuthInterceptor` in `lib/core/api/api_interceptors.dart` to inject session cookie and admin PIN header.
   - Update DI in `lib/core/api/api_client.dart` to inject `AuthSecureStorage`.
5. **Step 5: Auth Repository Implementation**
   - Create `flutter_client/lib/features/auth/infrastructure/auth_repository.dart`.
   - Implement `getMe()`, `loginWithPin()`, and `logout()`.
6. **Step 6: Riverpod Notifier & State Wiring**
   - Create `flutter_client/lib/features/auth/presentation/controllers/auth_notifier.dart`.
   - Create `flutter_client/lib/features/auth/presentation/providers/auth_providers.dart`.
   - Wire `hydrate()` in `lib/features/shell/presentation/screens/app_shell.dart`.
7. **Step 7: Automated Test Suites**
   - Implement unit tests for models, storage, repository, and notifier.
   - Run `flutter test test/features/auth/`.
   - Run `python scripts/probe_android_api.py` to ensure backend contracts remain intact.

---

## 5. Exit Criteria & Checkable Assertions

- [ ] **Static Analysis Clean:** `flutter analyze` returns zero errors and zero warnings across all modified and newly created files.
- [ ] **Secure Storage Operable:** Unit tests confirm `saveSessionToken`, `getSessionToken`, and `clearSessionToken` execute cleanly.
- [ ] **Cookie & Header Injection:** Interceptor tests prove requests carry `Cookie: session_token=<token>` when token exists, and omit it when cleared.
- [ ] **Session Hydration Verified:** Calling `hydrate()` with a valid token retrieves profile from `/api/auth/me` and transitions state to `AuthStatus.authenticated`.
- [ ] **PIN Login Operable:** Calling `loginWithPin()` against `/api/auth/login-pin` extracts session token and updates state.
- [ ] **Logout Clean:** Calling `logout()` invalidates state, wipes secure storage, and resets to `AuthStatus.unauthenticated`.
- [ ] **Backend Contract Probe Green:** `python scripts/probe_android_api.py` passes 22/22 endpoints.

---

## 6. Risks, Failure Modes & Mitigations

| Risk | Impact | Mitigation Strategy |
|:---|:---|:---|
| **Circular DI Loop** | Compile error or runtime DI recursion between `ApiClient` and `AuthRepository`. | Decouple storage from HTTP client: pass `AuthSecureStorage` directly into `DeviceAuthInterceptor` without passing `AuthRepository`. |
| **Android Keystore Hardware Lockout** | `FlutterSecureStorage` can throw `PlatformException` on certain customized Android ROMs. | Wrap storage operations in `try ... catch` returning graceful nulls and logging diagnostics instead of crashing app. |
| **401 Cascading Storm** | Background telemetry or polling calls receiving 401 could trigger repetitive logout loops. | Debounce 401 invalidation in the interceptor: only trigger session expiry once per active session token. |
| **Cookie Formatting Drift** | If Dio passes existing cookies, appending `session_token` improperly could malform the header. | Cleanly format `Cookie: <existing>; session_token=<token>` with trimming and semicolon separation. |

---

## 7. Open Decisions & User Preferences

1. **Session Cookie vs Bearer Token in Interceptor:**
   - **Decision:** Use `Cookie: session_token=<token>`.
   - **Rationale:** The Axum backend's `resolve_session_identity` natively extracts tokens from `Cookie` headers (`session_token` or `media_session`). This works 100% out of the box with zero backend changes.
2. **Admin PIN Persistence:**
   - **Decision:** Ephemeral in memory during active app session, with an optional "Remember PIN on this device" flag stored in secure storage.
