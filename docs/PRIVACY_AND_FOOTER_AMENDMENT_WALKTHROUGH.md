# Walkthrough: Web Footer Note, Privacy Policy & Flutter Privacy Transparency Parity

**Document Version:** 1.0  
**Completion Date:** 2026-11-23  
**Status:** Verification Completed (100% Passed)  

---

## 1. Executive Summary

We addressed the ambiguity in the web application's footer note where `"Zero telemetry"` stood in direct contradiction with the internal operational telemetry links (such as `"Devices Telemetry"`) and backend diagnostics. 

The amendment accurately repositions the privacy guarantee as **Zero Third-Party Tracking**, while enhancing disclosures to clearly distinguish strictly local first-party diagnostics from external tracking across both the **Web SPA (React 19)** and **Flutter Client (Android & Fire TV)** platforms.

---

## 2. Changes Delivered

### 2.1 Web Application (`web/src/app/AppShell.tsx`)
- **Footer Slogan Updated**:
  - Replaced:
    ```text
    Self-hosted private streaming · Zero telemetry · Direct hardware pipeline
    ```
  - With:
    ```text
    Self-hosted private streaming · Zero 3rd-party tracking · Direct hardware pipeline
    ```
- **Privacy Policy & Architecture Modal Enhanced**:
  - Expanded the modal into structured, transparent sections:
    1. **Zero Third-Party Tracking**: Affirmation that the platform contains zero advertising trackers, analytics SDKs, marketing beacons, or third-party cookies, and personal data is never shared.
    2. **First-Party Operational Diagnostics**: Transparent disclosure that operational telemetry (hardware GPU/CPU utilization, "Stats for Nerds" in-player metrics, client hints, and LAN/WAN presence heartbeats) is strictly first-party for local playback orchestration and is privacy-scoped to the active device by default.
    3. **Local Database Persistence**: Affirmation that watch progress, accounts, and device pairing tokens reside strictly in the local PostgreSQL database on the host machine.
    4. **External Media Metadata**: Transparent disclosure that the backend server makes direct API queries to TMDb solely to fetch poster artwork, ratings, and synopses during media indexing, with no user identities or watch logs attached.
    5. **Encrypted Remote Transport**: Transparent disclosure that Cloudflare Named Tunnels function strictly as an encrypted transport bridge without injected trackers or cookies.

### 2.2 Web Automated Test Suite (`web/src/app/AppShell.test.tsx`)
- Added two comprehensive test cases:
  1. Verified that the amended footer renders `"Zero 3rd-party tracking"`.
  2. Verified that opening the Privacy Policy modal displays all five disclosure sections and dismisses properly via the close button.

### 2.3 Flutter Client (`flutter_client/`)
- **New Reusable Dialog**: [`PrivacyPolicyDialog`](file:///e:/MediaServer/flutter_client/lib/features/settings/presentation/widgets/privacy_policy_dialog.dart)
  - Accessible, TV-focusable, and scrollable modal presenting the exact same architectural transparency principles as the web modal.
- **Settings Screen Integration**: [`settings_content.dart`](file:///e:/MediaServer/flutter_client/lib/features/settings/presentation/widgets/settings_content.dart)
  - Added an `"ABOUT & PRIVACY"` section at the bottom of the Settings list.
  - Features a `TvFocusable` tile titled `"Privacy Policy & Architecture"` with the subtitle `"Self-hosted private streaming · Zero 3rd-party tracking · Direct hardware pipeline"`.
  - Accessible via touch on mobile and D-pad navigation on Android TV / Fire TV Stick.
- **Automated Tests**:
  - Created [`privacy_policy_dialog_test.dart`](file:///e:/MediaServer/flutter_client/test/features/settings/privacy_policy_dialog_test.dart) testing dialog section rendering, close button dismissal, and header ✕ dismissal.
  - Updated [`settings_screen_test.dart`](file:///e:/MediaServer/flutter_client/test/features/settings/settings_screen_test.dart) to assert the presence of `"ABOUT & PRIVACY"` and the `"Privacy Policy & Architecture"` tile.

---

## 3. Verification & Test Outcomes

### Web Platform Checks
- **Vitest Unit & Component Suite**:
  ```powershell
  npm --prefix web run test
  ```
  **Result:** **46 test files passed, 340 tests passed** (including all `AppShell` tests).
- **TypeScript Typecheck**:
  ```powershell
  npm --prefix web run typecheck
  ```
  **Result:** Clean (`tsc -b` exited with code 0).
- **Oxlint Linter**:
  ```powershell
  npm --prefix web run lint
  ```
  **Result:** Clean (0 errors across 135 files).
- **Production Asset Build**:
  ```powershell
  npm --prefix web run build
  ```
  **Result:** Built in 1.26s (`dist/` generated cleanly).

### Flutter Platform Checks
- **Dart & Flutter Static Analysis**:
  ```powershell
  cd flutter_client; flutter analyze
  ```
  **Result:** `No issues found! (ran in 6.8s)`.
- **Flutter Widget Test Suite**:
  ```powershell
  cd flutter_client; flutter test test/features/settings/
  ```
  **Result:** **All 9 tests passed** (including `privacy_policy_dialog_test.dart`, `settings_screen_test.dart`, and `settings_sheet_test.dart`).

---

## 4. Deliverables Matrix

| File | Type | Description |
|---|---|---|
| [`web/src/app/AppShell.tsx`](file:///e:/MediaServer/web/src/app/AppShell.tsx#L582) | Modified | Updated footer slogan and expanded Privacy Policy & Architecture modal |
| [`web/src/app/AppShell.test.tsx`](file:///e:/MediaServer/web/src/app/AppShell.test.tsx#L143-L177) | Modified | Added unit tests for amended footer slogan and privacy modal interaction |
| [`flutter_client/lib/features/settings/presentation/widgets/privacy_policy_dialog.dart`](file:///e:/MediaServer/flutter_client/lib/features/settings/presentation/widgets/privacy_policy_dialog.dart) | New | TV/touch-friendly Privacy Policy & Architecture modal dialog |
| [`flutter_client/lib/features/settings/presentation/widgets/settings_content.dart`](file:///e:/MediaServer/flutter_client/lib/features/settings/presentation/widgets/settings_content.dart#L675-L750) | Modified | Added "ABOUT & PRIVACY" section and dialog launcher tile |
| [`flutter_client/test/features/settings/privacy_policy_dialog_test.dart`](file:///e:/MediaServer/flutter_client/test/features/settings/privacy_policy_dialog_test.dart) | New | Automated tests for privacy dialog rendering and dismissal |
| [`flutter_client/test/features/settings/settings_screen_test.dart`](file:///e:/MediaServer/flutter_client/test/features/settings/settings_screen_test.dart#L92-L93) | Modified | Asserted "ABOUT & PRIVACY" section and launcher tile |
| [`docs/PRIVACY_AND_FOOTER_AMENDMENT_PLAN.md`](file:///e:/MediaServer/docs/PRIVACY_AND_FOOTER_AMENDMENT_PLAN.md) | New | Authoritative implementation plan document |
| [`docs/PRIVACY_AND_FOOTER_AMENDMENT_WALKTHROUGH.md`](file:///e:/MediaServer/docs/PRIVACY_AND_FOOTER_AMENDMENT_WALKTHROUGH.md) | New | Verification walkthrough document |
