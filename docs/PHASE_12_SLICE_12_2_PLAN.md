# Implementation Plan — Phase 12 Slice 12.2: Mobile Phone Auth Views (Google OAuth CustomTab & Admin PIN Login)

**Phase:** Phase 12 (Mobile & TV Auth Parity & Native Admin Management)  
**Slice:** 12.2 (Mobile Phone Auth Views: Google OAuth CustomTab & Admin PIN Login)  
**Status:** Pending User Approval  
**Working Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Targets:** `flutter_client/`, `rust/src/routes/auth.rs`

---

## 1. Executive Summary & Purpose

With the authentication foundation, hardware-backed secure storage, and Riverpod `AuthNotifier` completed and verified in Slice 12.1, Slice 12.2 delivers the mobile phone user-facing authentication flows:
1. **Google OAuth via Chrome Custom Tabs:** Frictionless web OAuth flow reusing existing server credentials with deep-link redirection back to the Flutter app (`ahms://auth/callback?session_token=...`).
2. **Interactive Admin PIN Bottom Sheet:** Smooth, dark-themed numeric PIN sheet with masked digits, loading spinner, error feedback, and "Remember PIN" option.
3. **Account & Profile Screen in Settings:** Displays avatar, name, email, role badge (`Admin` / `Viewer` / `Guest`), sign-in triggers, and sign-out controls.
4. **Backend Mobile OAuth Bridge:** A lightweight handler at `GET /auth/callback/mobile` serving a dark obsidian HTML page that automatically launches the app's `ahms://` custom scheme with the session token.

---

## 2. Scope

### In-Scope (What Changes)
- **Backend Mobile OAuth Redirect Bridge (`rust/src/routes/auth.rs`):**
  - Add `GET /auth/callback/mobile` handler returning HTML with automatic JavaScript redirection to `ahms://auth/callback?session_token=<token>`.
- **Android Manifest Configuration (`flutter_client/android/app/src/main/AndroidManifest.xml`):**
  - Register an `<intent-filter>` in `MainActivity` matching scheme `ahms` and host `auth` with path `/callback`.
- **Flutter App Links / Deep Link Integration (`flutter_client/`):**
  - Add `url_launcher: ^6.3.0` to `pubspec.yaml`.
  - Add deep-link handler in GoRouter or app lifecycle service to capture incoming `ahms://auth/callback` URIs and pass `session_token` to `ref.read(authNotifierProvider.notifier).setSessionToken(token)`.
- **Mobile PIN Entry Sheet (`flutter_client/lib/features/auth/presentation/widgets/admin_pin_sheet.dart`):**
  - Modal bottom sheet with frosted obsidian aesthetics (`AppColors.surfaceElevated`, `AppColors.brandRed`).
  - Masked text field / PIN keypad, show/hide toggle, inline validation errors, and submit button.
- **Account & Profile Screen in Settings (`flutter_client/lib/features/auth/presentation/widgets/account_profile_card.dart`):**
  - Header profile card embedded in `SettingsScreen`.
  - Shows Avatar (Google photo or letter initial), Name, Email, and Role chip.
  - Sign-in actions (Google Sign-In button, Admin PIN button) when guest.
  - Sign-out button when authenticated.
- **Test Suites (`flutter_client/test/features/auth/`):**
  - `admin_pin_sheet_test.dart`: Widget test for PIN entry, validation, loading, and error states.
  - `account_profile_card_test.dart`: Widget test for Guest vs Viewer vs Admin states and sign-out action.

### Out-of-Scope (Deferred to Subsequent Slices)
- Android TV QR code display and remote D-pad input (`Slice 12.3`).
- Phone TV Pairing scanner/sheet (`Slice 12.3`).
- Full Admin Management views (Storage, Transcodes, Devices, Audit logs) (`Slice 12.4`).

---

## 3. Technical Design

### 3.1 Mobile OAuth Handshake Architecture

```
Flutter Phone App
   │
   ├─ User taps "Sign in with Google"
   │  └─ Launches Chrome Custom Tab: https://<server>/auth/google?next=/auth/callback/mobile
   │
Chrome Custom Tab
   │
   ├─ Redirects to accounts.google.com
   ├─ User completes Google login
   ├─ Redirects to https://<server>/auth/google/callback?code=...
   ├─ Axum validates code, mints session, sets Cookie: session_token=sess_...
   └─ Axum redirects to /auth/callback/mobile
         │
         └─ Serves HTML page:
            window.location.href = "ahms://auth/callback?session_token=sess_..."
               │
               ▼
Android OS catches ahms:// scheme
   │
   └─ Brings MainActivity to foreground
      └─ App router catches intent URI -> extracts `session_token`
         └─ Calls AuthNotifier.setSessionToken("sess_...")
            └─ Closes Custom Tab & App updates to Authenticated state!
```

### 3.2 Android Deep Link Registration

```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="ahms" android:host="auth" android:path="/callback" />
</intent-filter>
```

---

## 4. Step-by-Step Implementation Sequence

1. **Step 1: Backend Mobile Callback Route**
   - In `rust/src/routes/auth.rs`, implement `mobile_oauth_callback_handler` serving the deep-link redirection page.
   - Wire route in `rust/src/lib.rs`.
2. **Step 2: Dependencies & Android Manifest**
   - Add `url_launcher: ^6.3.0` to `flutter_client/pubspec.yaml`.
   - Add `<intent-filter>` in `flutter_client/android/app/src/main/AndroidManifest.xml`.
3. **Step 3: Deep Link & OAuth Launcher Service**
   - Create `flutter_client/lib/features/auth/infrastructure/oauth_launcher_service.dart`.
   - Wire incoming deep-link handling in `flutter_client/lib/main.dart` or `app_shell.dart`.
4. **Step 4: Interactive Admin PIN Entry Sheet**
   - Create `flutter_client/lib/features/auth/presentation/widgets/admin_pin_sheet.dart`.
   - Wire validation against `authNotifierProvider.notifier.loginWithPin(pin)`.
5. **Step 5: Account Profile Card in Settings**
   - Create `flutter_client/lib/features/auth/presentation/widgets/account_profile_card.dart`.
   - Integrate at the top of `flutter_client/lib/features/settings/presentation/screens/settings_screen.dart`.
6. **Step 6: Automated Test Suites**
   - Write widget tests in `flutter_client/test/features/auth/admin_pin_sheet_test.dart` and `account_profile_card_test.dart`.
   - Verify `flutter analyze` and `flutter test`.

---

## 5. Exit Criteria & Checkable Assertions

- [ ] `GET /auth/callback/mobile` on Rust backend responds with HTTP 200 and valid HTML containing the deep link script.
- [ ] `flutter analyze` returns zero errors and zero warnings.
- [ ] `AdminPinModalSheet` renders correctly, validates input, calls `loginWithPin`, and shows error state on failure.
- [ ] `AccountProfileCard` displays guest mode when unauthenticated, and user profile with role badge when authenticated.
- [ ] Tapping "Sign out" triggers `logout()` and resets card to guest mode.
- [ ] All auth unit and widget tests pass (`flutter test test/features/auth/`).
- [ ] `python scripts/probe_android_api.py` passes 22/22 endpoints.
