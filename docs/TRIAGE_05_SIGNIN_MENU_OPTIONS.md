# Triage & Fix Record — Issue 14.5: Header Sign-In Menu Options (Google vs QR)

**Date:** 2026-10-24 (IST)
**Issue:** [`docs/Current issues.md`](Current%20issues.md) → Issue 14, fault 5
**Branch:** `fix/issue-14-user-reported-faults`
**Status:** ✅ **Fixed and verified 2026-10-24**

---

## 1. Fault

Clicking **Sign in** in the web header called `signIn()` directly and landed in the Google
OAuth flow. It did not offer the QR sign-in path, even though the signed-out `/account` page
already had a complete QR Device Sign-In panel.

The original issue text said the QR option should be "disabled only in the TV variant". That
contradicted the QR flow itself: the TV/browser is the device that **displays** the QR, and the
phone is the device that **scans** it. The user's later clarification resolved the contradiction:

> disable showing qr only on phone or phone app... since phone will be used to scan the qr on web or tv

The stray "TV variant: QR disabled" line has been removed. The implemented rule is:

- **QR available on desktop, tablet and TV browsers.**
- **QR hidden on phone browsers.**
- **Flutter client untouched** — it has no Google/QR sign-in UI and identifies itself with its
  own `dev_…` device id.

## 2. Resolution

- The signed-out web header now renders `SignInMenu` on non-phone browsers.
- The menu offers:
  - **Continue with Google** — calls the existing `AuthProvider.signIn()` unchanged.
  - **Sign in with QR code** — a link to `/account`, where the existing `QrSignInPanel` owns the
    QR session, countdown, SSE wait stream and 14.4-fixed layout.
  - **Sign in with Admin PIN** — when OAuth is unconfigured, mirroring the QR panel. The Google
    item is omitted in that state rather than mislabelled.
- On a phone browser the header keeps a **direct sign-in button** (Google when configured, Admin
  PIN otherwise); no one-item menu and no QR.
- Opening the menu creates **no** QR session. Only the signed-out `/account` QR panel calls
  `POST /api/auth/qr`.
- Header-only scope: the signed-out `/account` QR panel remains unchanged and universal.
- The menu supports keyboard/remote operation: Enter/Space opens, Arrow Up/Down/Home/End moves,
  Escape closes and returns focus to the trigger, outside click and route change dismiss.

## 3. Behaviour matrix

| Context | Header behaviour |
|---|---|
| Desktop / tablet / TV browser, signed out, OAuth configured | Menu: **Continue with Google**, **Sign in with QR code** |
| Phone browser, signed out, OAuth configured | Direct **Sign in** (Google) button; QR hidden |
| OAuth unconfigured | Menu/direct action shows **Admin PIN**; QR remains on non-phone |
| Signed in | Existing avatar menu; unchanged |
| Flutter phone / TV | No sign-in UI; unchanged |

## 4. Implementation

- `web/src/lib/signInPlatform.ts` — pure `isPhoneBrowser()` helper plus `useIsPhoneBrowser()`.
  Detection uses `navigator.userAgentData.mobile`, phone user-agent tokens, then a
  phone-sized coarse-pointer fallback. It **fails open for an unrecognised user agent**: the QR
  option is kept rather than removing the only usable sign-in path on a camera-less device. The
  final coarse-pointer fallback treats a phone-sized touch viewport as a phone. iPad and Android
  tablets are treated as non-phones.
- `web/src/components/SignInMenu.tsx` — the chooser, menu items, focus management and dismissal.
  `AppShell` keys it by `location.pathname`, so a route change remounts it closed.
- `web/src/components/GoogleMark.tsx` — shared Google mark; `LoginScreen` now uses it.
- `web/src/components/icons.tsx` — added the `qr` glyph.
- `web/src/app/AppShell.tsx` — signed-out branch: phone → direct sign-in button (Google when
  configured, Admin PIN otherwise); otherwise → `SignInMenu`.
- `web/src/components/SignInMenu.test.tsx`, `web/src/lib/signInPlatform.test.ts`,
  `web/src/app/AppShell.test.tsx` — unit and integration coverage.
- `web/e2e/signin-menu.spec.ts` — desktop, 390 px overflow, OAuth-unconfigured, signed-in and
  phone-emulation coverage. The API is mocked; opening the menu is asserted to create no pair
  session, and `/account` is asserted to create one.

## 5. Verification (2026-10-24)

| Check | Result |
|---|---|
| `npm run typecheck` | pass |
| `npm run test` | **325/325**, 45 files |
| `npm run lint` | 0 errors; only pre-existing warnings, no new warning from `SignInMenu` |
| `npm run build` | pass |
| `npm run test:e2e -- signin-menu.spec.ts qr-layout.spec.ts` | **9/9** (5 new + 4 QR-layout regression) |
| `python scripts/probe_android_api.py` | **22/22** Android client endpoints per contract |
| Live smoke, 1280 px | menu opened; `aria-haspopup="menu"`; Google 1, QR 1; menu box `x=968, width=288` inside the viewport |
| Live smoke, 412 px phone UA | direct button; `aria-haspopup=null`; QR text count 0 |

The 14.4 regression gate still passes at 390 / 768 / 1280 px, and the signed-in `/account` state
still renders no QR and sends no `POST /api/auth/qr`.

No backend, API, session, QR-backend, QR-panel-layout or Flutter change was made. No Rust service
restart was required; only `web/dist` was rebuilt.

## 6. Risks / remaining

- Phone detection is necessarily heuristic. An unrecognised user agent keeps the QR option; the
  only fallback that can hide it is a coarse pointer with a sub-640 px viewport, which is a
  phone-shaped signal. A phone that masquerades as a desktop therefore keeps the QR option rather
  than a TV losing it.
- A TV browser with an unusual user agent that also reports a coarse pointer and a sub-640 px
  viewport would be classified as a phone. That combination is unlikely at TV resolutions; if it
  happens, the `/account` QR panel is still reachable directly, so QR remains available.
- The `/account` QR panel remains available to a phone that navigates there directly. This is
  deliberate for 14.5: the issue and fix are scoped to the header, and the account panel is the
  universal fallback.
