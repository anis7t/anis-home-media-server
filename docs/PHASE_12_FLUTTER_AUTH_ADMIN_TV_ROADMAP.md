# Phase 12 Roadmap — Mobile & TV Authentication Parity & Native Admin Management (Flutter)

**Status:** In Progress (Branch: `feat/phase-12-flutter-auth-admin-tv-parity`)  
**Targets:** Flutter Client (`flutter_client/` — Android Phone & Android TV / Fire TV) + Rust Axum Backend (`rust/`)  
**Design Decisions:**
- **Mobile Google OAuth:** In-app Custom Tabs / Chrome Custom Tabs via `/auth/google` with deep-link redirect (`ahms://auth/callback`), reusing server-configured Google OAuth Web Client credentials without requiring Android keystore SHA-1 / Google Play Console configuration.
- **Mobile Admin Hub:** Embedded in `SettingsScreen` (revealing Admin management tools when authenticated as admin, or prompting for Admin PIN if browsing as guest/viewer).
- **TV Authentication:** QR Code + 5-character pair code display with live SSE/polling + fallback D-pad remote numeric keypad for direct Admin PIN login.

---

## 1. Phase Architecture & Invariants

1. **Stack & Platform Parity:**
   - 100% Rust Axum backend on `:8000`, PostgreSQL 18.4 (`MediaServerPG`), React 19 web SPA, and Flutter client on Android Phone & Android TV.
   - All backend APIs are native Rust (`rust/src/routes/auth.rs`, `qr_auth.rs`, `admin.rs`, `storage.rs`, `jobs.rs`, `devices.rs`, `system.rs`, `scan.rs`).
   - Android API contract probe (`scripts/probe_android_api.py`) must remain 100% green with zero contract breakages.
2. **Session & Security Invariants:**
   - Client session tokens are persisted securely in `flutter_secure_storage`.
   - `DeviceAuthInterceptor` injects persistent `X-Device-Id`, `User-Agent`, and session credentials (`Cookie: session_token=<token>` and `X-Admin-Pin: <pin>`).
   - Admin operations fail closed if unauthenticated or unauthorized.
3. **Dual Form Factor Adaptation:**
   - Phone: Touch-first UI, portrait-optimized, bottom navigation shell, Google OAuth CustomTab, bottom sheets for PIN entry and TV pairing scanner.
   - Android TV / Fire TV: D-pad / remote control navigation, landscape 1080p layout, spatial focus traversal, oversized QR display with legible 5-character code, and on-screen 10-key remote keypad.

---

## 2. Phase 12 Slices & Sub-Items

### Slice 12.1: Flutter Authentication Foundation & Persistent Session Infrastructure
- **12.1a — Data Models & Secure Storage:**
  - Define `AuthSession`, `UserIdentity`, and `AuthRole` (`admin`, `viewer`, `guest`).
  - Implement `AuthSecureStorage` wrapping `flutter_secure_storage` with fallback to `shared_preferences` for non-sensitive cached state (e.g. last signed-in email/display name).
- **12.1b — Auth Repository & API Client Integration:**
  - Implement `AuthRepository` with endpoints:
    - `GET /api/auth/me` (session hydration).
    - `POST /api/auth/login-pin` (Admin PIN login).
    - `POST /auth/logout` (session invalidation).
- **12.1c — Interceptor & Header Injection:**
  - Update `DeviceAuthInterceptor` in `lib/core/api/api_interceptors.dart` to automatically attach:
    - `Cookie: session_token=<stored_token>`
    - `X-Admin-Pin: <stored_or_transient_pin>` (when active)
  - Handle 401 Unauthorized responses gracefully (trigger session expiry callback in auth state).
- **12.1d — Riverpod State Management (`AuthNotifier`):**
  - Implement `authNotifierProvider` (`AsyncNotifier<AuthState>`) managing: `unauthenticated`, `authenticating`, `authenticated`, `error`.
  - Wire startup session hydration in `main.dart` or `app_shell.dart`.
- **12.1e — Test Suite & Verification:**
  - Unit tests for `AuthSecureStorage`, `AuthRepository`, and `AuthNotifier`.
  - Mock interceptor test verifying session token and PIN injection.

---

### Slice 12.2: Mobile Phone Auth Views (Google OAuth & Admin PIN Login) — ✅ COMPLETE & VERIFIED
- **12.2a — Google OAuth Mobile Flow:**
  - In-app Custom Tabs / external browser launcher directing to `<server_url>/auth/google?next=/auth/callback/mobile`.
  - Android deep-link intent-filter registration in `AndroidManifest.xml` (`ahms://auth/callback?session_token=...`).
  - Auth callback listener in GoRouter / App Lifecycle to capture returned session token, store it, and refresh auth state.
- **12.2b — Admin PIN Entry Bottom Sheet:**
  - Compact, responsive numeric keypad sheet (with masked digits, show/hide toggle, loading spinner, and error shake).
  - Validates against `POST /api/auth/login-pin`, transitions auth state to Admin upon success.
- **12.2c — Account & Profile Screen in Settings:**
  - Displays user avatar, name, email, and role badge (`Admin` / `Viewer` / `Guest`).
  - Sign-in actions when unauthenticated (Google Sign-In button + Admin PIN button).
  - Sign-out action when authenticated, clearing secure storage and resetting auth state.
- **12.2d — Test Suite & Verification:**
  - Widget tests for Account profile rendering, PIN entry sheet validation, and sign-out workflow.

---

### Slice 12.3: Android TV Remote Authentication (QR Sign-In & On-Screen PIN Pad) — ✅ COMPLETE & VERIFIED
- **12.3a — TV QR Pair Lifecycle & State Machine:**
  - Service for managing pairing session: calls `POST /api/auth/qr` to obtain `qr_id`, 5-char `code`, `sig`, `expires_at`, and `qr_url`.
  - Background SSE listener (`GET /api/auth/qr/{id}/wait`) with 3-second fallback polling (`GET /api/auth/qr/{id}/status`).
  - Finalize handler (`GET /api/auth/qr/{id}/finalize`) to claim session token upon phone confirmation.
- **12.3b — Android TV QR Pairing Screen:**
  - High-contrast, large QR code widget (rendered via `qr_flutter`).
  - Prominent 5-character pair code display (e.g. `K  9  X  2  P`) with 2-minute countdown timer and auto-refresh.
  - Spatial focus D-pad navigation between QR view and direct PIN sign-in button.
- **12.3c — Android TV On-Screen D-Pad Keypad for Admin PIN:**
  - TV-native 10-key numeric keypad navigable via D-pad arrows (Up/Down/Left/Right/Enter) with Backspace and Submit.
  - Allows direct Admin login on TV without needing a phone nearby.
- **12.3d — Phone Remote Pairing Sheet / Scanner:**
  - Mobile interface in Phone Settings ("Pair Android TV / Remote Device").
  - Allows entering the 5-character code shown on TV (or optional camera scan).
  - Asks for a friendly device name (e.g. "Living Room TV") and calls `POST /api/auth/qr/{id}/confirm`.
- **12.3e — Test Suite & Verification:**
  - TV QR pairing widget tests, D-pad navigation tests, expiry timer resilience, and Phone confirmation integration tests.

---

### Slice 12.4: Native Admin Management Hub in Mobile Settings
- **12.4a — Embedded Admin Hub in Settings:**
  - Added to `SettingsScreen`: "Admin & Server Management" tile.
  - Role-gated: visible to Admins; if tapped by Guest/Viewer, prompts for Admin PIN to unlock management mode.
- **12.4b — Storage Telemetry & Retention Management Screen:**
  - Storage Pool HUD displaying Drive `D:` and `E:` capacity, free space, and headroom.
  - Retention Policy selector (`keep`, `archive`, `purge_cache`) backed by `/api/storage/settings`.
  - Orphaned Cache Audit card and one-click "Purge Orphaned Caches" button (`/api/storage/purge-orphans`).
  - Library Media Inventory overview with file sizes and codec breakdown.
- **12.4c — Transcode Dashboard & Dual-GPU Telemetry Screen:**
  - Real-time Dual-GPU Telemetry card (Discrete AMD Radeon RX 560X and Integrated Vega 8 engine & VRAM utilization).
  - Active Transcode Jobs rail showing running title, quality, assigned GPU, speed, fps, ETA, and chunk progress bar.
  - Job management actions: Cancel running transcode (`POST /api/transcode/jobs/{filename}/cancel`).
  - Recent jobs history log (completed, canceled, failed).
- **12.4d — Connected Devices Management Screen:**
  - Real-time list of all registered clients (`GET /api/devices`) with active (🟢), idle (🟡), and offline (⚪) status chips.
  - Metadata badges: Hardware model, OS version, IP address, network path (LAN / Cloudflare Tunnel / WAN), last active timestamp.
  - Device actions: Friendly renaming modal (`POST /api/devices/{id}/rename`) and Revoke/Forget device (`DELETE /api/devices/{id}`).
- **12.4e — Library Maintenance & Security Tools:**
  - Manual TMDb Library Scan trigger button (`POST /api/scan`) with live scanning spinner and status banner (`GET /api/scan/status`).
  - Admin PIN Rotation modal (`POST /api/admin/change-pin`).
  - Security Audit Logs viewer (`GET /api/admin/audit-logs`) with filtering by actor and action.
- **12.4f — Test Suite & Verification:**
  - Admin hub navigation tests, storage telemetry widget tests, transcode dashboard telemetry tests, and device management tests.

---

### Slice 12.5: Full End-to-End Verification, Performance & Documentation
- **12.5a — Automated Test Suite & API Parity:**
  - Run full Flutter unit and widget test suites (`flutter test`).
  - Run backend regression suites (`cargo test --lib`, `cargo test --test qr_auth_test`, etc.).
  - Run Android API contract probe (`python scripts/probe_android_api.py`) verifying 22/22 endpoints intact.
- **12.5b — Cross-Form Factor Verification:**
  - Phone: Verified portrait layout, touch gestures, custom tab redirect, keyboard handling.
  - TV: Verified 1080p landscape layout, D-pad spatial focus, QR legibility from 10ft viewing distance, remote keypad.
- **12.5c — Documentation & Walkthrough:**
  - Update `docs/PROJECT_STATUS.md`.
  - Create `docs/PHASE_12_WALKTHROUGH.md` with full deliverable verification and testing evidence.
