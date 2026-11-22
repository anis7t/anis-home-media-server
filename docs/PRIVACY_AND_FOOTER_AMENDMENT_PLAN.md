# Implementation Plan: Web Footer Note, Privacy Policy & Flutter Privacy Transparency Parity

**Document Version:** 1.0  
**Target Date:** 2026-11-23  
**Status:** Pending User Approval  

---

## 1. Context & Motivation

In the webapp footer ([`web/src/app/AppShell.tsx`](file:///e:/MediaServer/web/src/app/AppShell.tsx#L582)), the slogan states:
> `Self-hosted private streaming · Zero telemetry · Direct hardware pipeline`

While this claim is completely justified regarding **zero third-party surveillance, tracking, and advertising** (zero analytics SDKs, zero marketing pixels, zero 3rd-party cookies, and 100% self-hosted assets), it technically contradicts the app's internal operational diagnostics:
1. The footer itself contains a link titled **"Devices Telemetry"** ([`AppShell.tsx:563`](file:///e:/MediaServer/web/src/app/AppShell.tsx#L563)).
2. The platform actively monitors first-party telemetry:
   - Client device hints and heartbeats (`/api/devices/*`).
   - Playback quality metrics in "Stats for Nerds" (`v.getVideoPlaybackQuality()`).
   - Hardware multi-GPU utilization telemetry (`/api/system/stats`).
3. The server communicates with TMDb (`api.themoviedb.org`) to fetch artwork, ratings, and synopses during library scanning, which should be disclosed.
4. The Flutter client (`flutter_client/`) currently lacks an in-app Privacy Policy or Architecture transparency modal in its Settings screen, leaving a feature gap compared to the Web client.

---

## 2. Scope

### In Scope
1. **Web App Footer Note Amendment**:
   - Update [`web/src/app/AppShell.tsx`](file:///e:/MediaServer/web/src/app/AppShell.tsx#L582) to replace `"Zero telemetry"` with:
     ```text
     Self-hosted private streaming · Zero 3rd-party tracking · Direct hardware pipeline
     ```
2. **Web App Privacy Policy Modal Enhancement**:
   - Update the modal content in [`web/src/app/AppShell.tsx`](file:///e:/MediaServer/web/src/app/AppShell.tsx#L621-L632) to clearly delineate:
     - **Zero Third-Party Surveillance**: No trackers, advertising networks, analytics SDKs, or data brokers.
     - **First-Party Operational Diagnostics**: Local device hints, playback performance metrics ("Stats for Nerds"), and GPU utilization are recorded strictly for local playback orchestration and fleet management, persisted only in your host PostgreSQL database (`MediaServerPG`), and privacy-scoped to your current device by default.
     - **External Media Metadata Queries**: Explain that the backend server makes direct API calls to The Movie Database (TMDb) solely to fetch poster artwork, ratings, and synopses during media indexing, without sending user identities or watch logs.
     - **Encrypted Remote Transport**: Reiterate that Cloudflare Named Tunnels act strictly as an encrypted transport bridge.
3. **Web App Unit & Regression Testing**:
   - Add unit tests in [`web/src/app/AppShell.test.tsx`](file:///e:/MediaServer/web/src/app/AppShell.test.tsx) verifying:
     - The amended footer text is rendered.
     - Clicking "Privacy Policy" opens the dialog with all key disclosure sections.
     - The dialog closes properly on Close button and ✕ button.
4. **Flutter Client Privacy Transparency Parity**:
   - Create a reusable, TV/D-pad accessible `PrivacyPolicyDialog` in `flutter_client/lib/features/settings/presentation/widgets/privacy_policy_dialog.dart` reflecting the same transparency guarantees.
   - Add an `"ABOUT & PRIVACY"` section to [`flutter_client/lib/features/settings/presentation/widgets/settings_content.dart`](file:///e:/MediaServer/flutter_client/lib/features/settings/presentation/widgets/settings_content.dart) with a focusable `TvFocusable` tile: `"Privacy & Architecture"`.
   - Add widget test in `flutter_client/test/features/settings/privacy_policy_dialog_test.dart` to verify dialog opening, content rendering, and D-pad/touch dismissal.

### Out of Scope (Deliberately Unchanged)
- **Operational telemetry endpoints & routes**: `/api/devices/*`, `/api/system/stats`, `/api/transcodes` remain 100% unchanged.
- **Backend Rust code**: No changes required in `rust/`.
- **Database schema**: No changes to PostgreSQL.
- **Navigation labels**: `"Devices Telemetry"` and `"Client Presence Telemetry"` links remain intact to preserve familiar operational diagnostics terminology.

---

## 3. Exit Criteria

1. **Web Frontend**:
   - `npm --prefix web run test` passes with 100% passing tests (including new AppShell tests).
   - `npm --prefix web run typecheck` passes with zero TypeScript errors.
   - `npm --prefix web run lint` (oxlint) passes with zero warnings.
2. **Flutter Client**:
   - `cd flutter_client; flutter analyze` passes with zero errors/warnings.
   - `flutter test test/features/settings/` passes.
3. **User Verification**:
   - Web footer renders: `"Self-hosted private streaming · Zero 3rd-party tracking · Direct hardware pipeline"`.
   - Web Privacy Policy modal renders clear disclosures for 3rd-party tracking, operational diagnostics, local DB persistence, TMDb indexing, and tunnel transport.
   - Flutter Settings screen contains an "ABOUT & PRIVACY" section that opens the new dialog on both mobile touch and TV D-pad.

---

## 4. Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Broken TV D-pad navigation on Fire TV / Android TV | Medium | Use `TvFocusable` with standard border/glow styles and proper `ExcludeFocus` encapsulation as established in `settings_content.dart`. |
| Modal trapping / CSS stacking context issues on Web | Low | Modal is already portaled to `document.body` via `createPortal(..., document.body)`. Maintain portal structure. |
| Stale text assertions in test suite | Low | Run full test suite before and after editing to ensure all expectations align. |

---

## 5. Open Decisions

1. **Footer Slogan Phrasing**:
   - **Recommended:** `Self-hosted private streaming · Zero 3rd-party tracking · Direct hardware pipeline`
   - Alternative: `Self-hosted private streaming · 100% private & tracker-free · Direct hardware pipeline`
2. **Privacy Policy Structure**:
   - Bulleted transparency format with distinct subtitles (Third-Party Tracking, Operational Telemetry, External Metadata, Local Database Storage) for maximum clarity and scannability.
