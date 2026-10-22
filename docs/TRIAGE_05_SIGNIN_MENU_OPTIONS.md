# Triage Plan — Issue 14.5: Header Sign-In Menu Shows Google Only (QR Should Be TV-Only)

**Date:** 2026-10-23 (IST 03-18)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → Issue 14, fault 5
**Branch:** `fix/issue-14-user-reported-faults`

---

## 1. Fault

Clicking **Sign in** in the header lands **directly** into the Google sign-in flow, instead of
showing **both** the Google sign-in option and the QR scan option. The QR scan option should be
**disabled only in the TV variant** of the app.

## 2. Context

- Sign-in options: Google (OIDC) and QR pairing (web + TV).
- Issue 5/6 (Phase 3) resolved admin gating for pairing tokens; the menu surface itself may be
  mis-scoped.

## 3. Hypotheses

1. The header auth menu branches on platform without distinguishing web vs TV.
2. The menu conditionally omits QR based on auth state rather than platform.

## 4. Verification approach

- Inspect header auth menu implementation; compare web vs TV menu gating.

## 5. Exit criteria

- Web menu shows both Google and QR; TV variant shows appropriate options (QR disabled for TV).

## 6. Risks / open decisions

- Auth-adjacent UI; keep `/api/*` contract unchanged; TV behaviour must not regress.

---

**Next step (pending approval):** inspect and fix menu option set.
