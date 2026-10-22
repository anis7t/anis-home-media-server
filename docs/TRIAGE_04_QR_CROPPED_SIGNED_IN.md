# Triage Plan — Issue 14.4: Unscannable QR Code (Signed-In Devices Menu, Web)

**Date:** 2026-10-23 (IST 03-18)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → Issue 14, fault 4
**Branch:** `fix/issue-14-user-reported-faults`

---

## 1. Fault

In the **signed-in** state, the QR code displayed in the devices menu is **cropped / not fully
displayed**, making it unscannable.

## 2. Context

- QR sign-in feature (branch `feature/qr-signin-web-tv`, walkthrough in
  [`docs/QR_SIGNIN_WALKTHROUGH.md`](../docs/QR_SIGNIN_WALKTHROUGH.md)).
- Issue 8 (2026-10-20) found and fixed several QR defects; display cropping was not among them.

## 3. Hypotheses

1. CSS overflow / sizing in signed-in variant.
2. QR component rendering in a modal/drawer with fixed dimensions.
3. Signed-in vs guest layout differences.

## 4. Verification approach

- Reproduce in signed-in state on web; inspect rendered QR element geometry.

## 5. Exit criteria

- QR fully displayed and scannable in signed-in state.

## 6. Risks / open decisions

- UI-only; keep TV variant behaviour unchanged.

---

**Next step (pending approval):** reproduce, then fix.
