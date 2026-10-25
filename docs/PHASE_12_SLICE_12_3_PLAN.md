# Implementation Plan — Phase 12 Slice 12.3: Android TV Remote Authentication (QR Sign-In & On-Screen PIN Pad)

**Phase:** Phase 12 (Mobile & TV Auth Parity & Native Admin Management)  
**Slice:** 12.3 (Android TV Remote Authentication: QR Sign-In, On-Screen D-Pad PIN Pad & Phone Pairing Sheet)  
**Working Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Date:** 2026-10-24  

---

## 1. Scope & Boundaries

### In Scope
1. **QR Pairing Domain Models & Repository (`QrAuthRepository`):**
   - Models: `QrPairSession` (`qrId`, `code`, `sig`, `expiresAt`, `qrUrl`, `loginUrl`), `QrStatus` (`pending`, `confirmed`, `expired`), `QrLookupResult`.
   - API Client calls:
     - `POST /api/auth/qr` (creates session, captures `ms_qr_secret` cookie).
     - `GET /api/auth/qr/{id}/status` (polls pair status).
     - `GET /api/auth/qr/{id}/finalize` (claims `session_token` cookie with `followRedirects: false`).
     - `POST /api/auth/qr/lookup` (phone resolves 5-char code to `qr_id`).
     - `POST /api/auth/qr/{id}/confirm` (phone confirms pair with `device_name` and `code`/`sig`).
2. **TV QR State Machine (`TvQrPairController`):**
   - Riverpod `AutoDisposeAsyncNotifier<TvQrPairState>` managing: `initializing`, `waiting(session, remainingSeconds)`, `confirmed`, `expired`, `error`.
   - High-precision 1-second countdown timer for the 2-minute pairing window.
   - 2.5-second polling loop for `/api/auth/qr/{id}/status`.
   - Auto-finalize and session token extraction upon `confirmed` status, calling `AuthNotifier.setSessionToken(token)`.
3. **Android TV QR Pairing Screen / Modal (`TvQrPairingScreen`):**
   - High-contrast obsidian TV layout with `qr_flutter` canvas painting.
   - Oversized, high-legibility 5-character pair code display (e.g. `K  9  X  2  P`).
   - 2-minute countdown timer with automatic "↻ Refresh Code" action when expired.
   - D-pad spatial focus navigation between "Switch to Admin PIN" and "Close".
4. **Android TV On-Screen D-Pad Keypad (`TvAdminPinPad`):**
   - 10-key numeric grid (`0`–`9`, `⌫ Clear`, `✓ Submit`) navigable via D-pad arrows (Up/Down/Left/Right/Center).
   - 4-digit masked PIN display with focus rings and active digit indicators.
   - Direct authentication against `AuthNotifier.loginWithPin(pin)`.
   - Visual error feedback on invalid PIN.
5. **Phone Pairing Sheet (`TvPairingSheet`):**
   - Mobile modal bottom sheet in Phone Settings -> `AccountProfileCard`: "Link TV / Remote Device".
   - 5-character code input with auto-capitalization and formatting.
   - Friendly device name input (defaulting to "Living Room TV").
   - One-tap validation and pairing confirmation.
6. **TV Account Profile Card in Settings (`TvAccountProfileCard`):**
   - TV-adapted card displayed on `SettingsScreen` when `isTv == true`:
     - Unauthenticated: "Sign in to Media Server" with "Pair with Phone (QR Code)" and "Admin PIN Sign-In" focusable buttons.
     - Authenticated: Avatar, user name, role badge (`ADMIN` / `VIEWER`), and "Sign Out" button.
7. **Comprehensive Automated Tests:**
   - Unit tests for `QrAuthRepository`.
   - State machine tests for `TvQrPairController`.
   - Widget tests for `TvQrPairingScreen` and `TvAdminPinPad`.
   - Widget tests for `TvPairingSheet` on phone.
   - Regression verification of `SettingsScreen` and `AppShell`.

### Deliberately Out of Scope
- Native camera barcode scanner on phone (Phase 12 uses clean 5-character code entry; direct camera scanning can be added later without API changes).
- Admin management views & telemetry dashboards (reserved for **Slice 12.4: Native Admin Management Hub in Settings**).

---

## 2. Architecture & Design Details

```
+-----------------------------------------------------------------------------------------+
|                                     Android TV                                          |
|                                                                                         |
|  [TvAccountProfileCard] ---> [TvQrPairingScreen]                                        |
|                                  | (POST /api/auth/qr)                                  |
|                                  v                                                      |
|                             Displays QR Code + "K 9 X 2 P"                              |
|                             Polls /api/auth/qr/{id}/status                              |
|                                  |                                                      |
|  [TvAdminPinPad] (Fallback)      | (status == confirmed)                                |
|  - D-Pad 10-key numeric keypad   v                                                      |
|  - Calls loginWithPin(pin)  Calls /api/auth/qr/{id}/finalize                            |
|                             Saves session_token -> TV signed in!                        |
+----------------------------------+------------------------------------------------------+
                                   ^
                                   | HTTP API (Rust Axum :8000)
                                   v
+----------------------------------+------------------------------------------------------+
|                                    Android Phone                                        |
|                                                                                         |
|  [SettingsScreen] -> [AccountProfileCard] -> "Link TV / Remote Device"                  |
|                                  |                                                      |
|                                  v                                                      |
|                          [TvPairingSheet]                                               |
|                          1. Enter "K9X2P"                                               |
|                          2. Device Name: "Living Room TV"                               |
|                          3. POST /api/auth/qr/lookup -> gets qr_id                      |
|                          4. POST /api/auth/qr/{id}/confirm                              |
|                          5. Success! TV instantly logs in.                              |
+-----------------------------------------------------------------------------------------+
```

### Cookie Proof-of-Ownership Handling in Flutter
In the Axum backend, `POST /api/auth/qr` issues a path-scoped cookie:
`Set-Cookie: ms_qr_secret=<secret>; Path=/api/auth/qr/<qr_id>; HttpOnly; SameSite=Lax`
For the TV to finalize cleanly via `GET /api/auth/qr/<qr_id>/finalize`, it must pass back `Cookie: ms_qr_secret=<secret>`.
- `QrAuthRepository` will capture `ms_qr_secret` from the response `set-cookie` header of `POST /api/auth/qr` and store it in the active session model.
- When calling `GET /api/auth/qr/<qr_id>/finalize`, it explicitly attaches `Cookie: ms_qr_secret=<secret>` in `Options(headers: ...)`.
- It sets `followRedirects: false` on the finalize call so that Dio does not follow the `307 Temporary Redirect` to `/`, allowing direct extraction of `Set-Cookie: session_token=<token>` from the 307 response!

---

## 3. Exit Criteria
1. `qr_flutter: ^4.1.0` added to `pubspec.yaml` with clean resolution.
2. `QrAuthRepository` implements session creation, status polling, code lookup, pairing confirmation, and finalization.
3. `TvQrPairingScreen` displays crisp QR code, legible 5-character pairing code, and active 2-minute countdown timer.
4. `TvAdminPinPad` provides full D-pad grid navigation across digits 0–9, Backspace, and Submit, validating PIN against `AuthNotifier`.
5. `TvPairingSheet` on phone allows entering code and device name, confirming pairing via API with success feedback.
6. `TvAccountProfileCard` on TV displays login options when unauthenticated and profile details with Sign Out when authenticated.
7. All automated unit and widget tests pass (`flutter test test/features/auth/`).
8. `flutter analyze` reports 0 errors and 0 warnings.
9. Backend contract probe (`scripts/probe_android_api.py`) remains 22/22 green.

---

## 4. Risks & Mitigations
- **Risk 1: Expiry during pairing:** If a user takes longer than 2 minutes to scan or type the code, the pairing session expires.
  - *Mitigation:* The TV state machine detects `status: "expired"` or local timer expiry, displays "Code expired", and provides an immediate D-pad focused "↻ Generate New Code" button.
- **Risk 2: Network drop or proxy timeout during polling:**
  - *Mitigation:* Status polling uses bounded 2.5s intervals with retry tolerance (3 consecutive failures before displaying an error banner) and cancels immediately when the widget is disposed or popped.
- **Risk 3: Accidental navigation away from TV QR screen:**
  - *Mitigation:* Timer and polling are encapsulated in an `AutoDispose` Riverpod notifier, cleanly stopping timers and releasing HTTP connections on disposal.
