# Phase 12 Slice 12.3 Walkthrough — Android TV Remote Authentication (QR Sign-In & On-Screen PIN Pad)

**Status:** Complete & Verified  
**Date:** 2026-10-24  
**Branch:** `feat/phase-12-flutter-auth-admin-tv-parity`  
**Targets:** Flutter Client (`flutter_client/` — Android Phone & Android TV / Fire TV) + Rust Axum Backend (`rust/`)

---

## 1. Overview & Objectives

Slice 12.3 delivers complete Android TV remote authentication parity to the Flutter client, enabling TV viewers to authenticate seamlessly without physical keyboards or cumbersome virtual text entry:
1. **Oversized QR Code Sign-In:** 10-foot viewing distance optimized QR code rendering with live countdown timer and 5-character pair code display.
2. **Real-Time Pairing Coordination:** TV pair session lifecycle management with SSE/polling status detection and automatic token finalization upon mobile approval.
3. **On-Screen D-Pad Keypad for Admin PIN:** TV-native 10-key numeric keypad navigable via remote control arrow keys (Up/Down/Left/Right/Select) with clear and submit actions.
4. **Phone Remote Pairing Sheet:** Mobile interface for authenticated users to link an Android TV by entering the 5-character pair code and giving the TV a friendly name.

---

## 2. Changes Delivered

### A. Dependencies & API Endpoints
- **Dependencies (`flutter_client/pubspec.yaml`):** Added `qr_flutter: ^4.1.0` for rendering crisp vector-based QR codes on 1080p and 4K displays.
- **Dynamic API Endpoints (`lib/core/api/api_endpoints.dart`):**
  - `qrStatus(id)`: `GET /api/auth/qr/{id}/status`
  - `qrConfirm(id)`: `POST /api/auth/qr/{id}/confirm`
  - `qrFinalize(id)`: `GET /api/auth/qr/{id}/finalize`
  - `qrWait(id)`: `GET /api/auth/qr/{id}/wait`

### B. Domain Models & Network Layer
- **Domain Models (`lib/features/auth/domain/models/qr_pair_session.dart`):**
  - `QrPairSession`: Holds `qrId`, `code` (5-char uppercase), `sig`, `expiresAt`, `qrUrl`, and `secretCookie` (captured from `Set-Cookie: ms_qr_secret`).
  - `QrPairStatus`: Represents `waiting`, `confirmed` (with `confirmedBy` name), and `expired`.
  - `QrLookupResult`: Model for resolving 5-character pairing codes on mobile.
- **QR Auth Repository (`lib/features/auth/infrastructure/qr_auth_repository.dart`):**
  - `createPairSession()`: Initiates a new pairing session via `POST /api/auth/qr` and extracts the cryptographic `ms_qr_secret` cookie.
  - `getPairStatus(qrId)`: Queries `GET /api/auth/qr/{id}/status`.
  - `finalizePairSession(qrId, secretCookie)`: Calls `GET /api/auth/qr/{id}/finalize` with `followRedirects: false` and the secret cookie, capturing the returned `session_token` cookie and persisting it in secure storage.
  - `lookupPairCode(code)`: Queries `GET /api/auth/qr/code/{code}` to validate pairing codes.
  - `confirmPairSession(qrId, deviceName)`: Posts `POST /api/auth/qr/{id}/confirm` to approve the TV pairing from an authenticated phone session.

### C. State Management & Controllers
- **TV QR Pair Controller (`lib/features/auth/presentation/controllers/tv_qr_pair_controller.dart`):**
  - Extends `Notifier<TvQrPairState>`.
  - Manages 1-second countdown timer, 3-second status polling loop, and cancellation upon widget disposal.
  - Automatically triggers `finalizePairSession()` when status switches to `confirmed`, refreshing the global `AuthNotifier` to transition the TV into authenticated state.

### D. User Interface & TV Focus Widgets
- **On-Screen D-Pad Keypad (`lib/features/auth/presentation/widgets/tv_admin_pin_pad.dart`):**
  - 10-key numeric keypad (`0`–`9`, `⌫ Clear`, `✓ Submit`) arranged in a spatial 3×4 grid.
  - Spatial focus traversal using `FocusNode` with gold border focus states (`AppColors.accentPrimary`).
  - Physical D-pad remote listener (`RawKeyboardListener` / `Focus`) supporting DPAD direction keys, Enter/Select, and Back.
  - 4 masked digit slots with error shake feedback and "Remember Admin PIN" toggle.
- **Android TV QR Pairing Screen (`lib/features/auth/presentation/widgets/tv_qr_pairing_screen.dart`):**
  - Two-column 1080p landscape layout: Left side displays 220px `QrImageView` with rounded obsidian frame; Right side displays step-by-step instructions, oversized 5-character pair code (`K 9 X 2 P`), countdown timer with animated indicator, and auto-refresh button.
  - Mode toggle allowing direct switch between QR Code sign-in and D-Pad Admin PIN pad.
- **Phone Pairing Sheet (`lib/features/auth/presentation/widgets/tv_pairing_sheet.dart`):**
  - Modal bottom sheet opened from Phone Settings (`AccountProfileCard`).
  - 5-character pairing code input with auto-capitalization and automatic code lookup.
  - Device friendly name input (defaults to "Living Room Android TV").
  - "Link Android TV" confirmation button calling `confirmPairSession()`.
- **TV Account Profile Card (`lib/features/auth/presentation/widgets/tv_account_profile_card.dart`):**
  - Embedded in `SettingsScreen` when `isTv == true`.
  - Displays authenticated TV user badge or Guest mode with prominent D-pad focusable "Sign in with QR Code" and "Admin PIN Keypad" actions.

---

## 3. Verification & Test Outcomes

### Unit & Widget Tests
Full auth test suite executed:
```
00:09 +51: All tests passed!
```
- `qr_auth_repository_test.dart`: 6/6 tests passing (session creation, cookie extraction, status polling, token finalization, code lookup, pairing confirmation).
- `tv_admin_pin_pad_test.dart`: 4/4 tests passing (keypad rendering, digit entry, D-pad focus traversal, error handling).
- `tv_pairing_sheet_test.dart`: 4/4 tests passing (sheet rendering, code validation, lookup success/failure, TV linking).
- `tv_qr_pairing_screen_test.dart`: 4/4 tests passing (QR render, countdown timer, expiry handling, mode toggle).
- `tv_account_profile_card_test.dart`: 2/2 tests passing (guest mode actions, authenticated profile details).

### Static Analysis & Rust Backend Checks
- `flutter analyze`: **No issues found! (ran in 8.4s)**. Zero warnings, zero errors.
- `cargo check --lib`: **Finished `dev` profile in 1.33s** with zero errors.
- `scripts/probe_android_api.py`: **22/22 Android endpoints OK** per contract.
