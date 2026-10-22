# Triage Plan — Issue 14.6: Add-Device Flow (QR Code / URL / Token)

**Date:** 2026-10-23 (IST 03-18)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → Issue 14, fault 6
**Branch:** `fix/issue-14-user-reported-faults`

---

## 1. Fault

In the devices menu, the **Add device** option: after entering a device name it shows a **QR code,
a URL and a token**. The owner asks:

- What am I supposed to do with the QR code?
- The URL is **non-functional**.
- Where was I supposed to enter the token?
- Why does this whole thing exist, since QR login is already handled?

## 2. Context

- Existing pairing machinery: `POST /api/auth/pairing-token/mint` + claim; Issue 4/5/6 resolutions
  (token engine, user-scoped minting, admin gating).
- QR sign-in walkthrough: [`docs/QR_SIGNIN_WALKTHROUGH.md`](../docs/QR_SIGNIN_WALKTHROUGH.md).

## 3. Hypotheses / questions

1. Add-device may be intended as the *physical pairing* path (TV) while QR sign-in is the *human
   sign-in* path — conflated by the owner.
2. The URL/token may be remnants of an older flow.

## 4. Verification approach

- Map current UI strings/labels to backend endpoints; test the URL with the token.

## 5. Exit criteria

- Flow is unambiguous: owner knows what to do with QR vs URL vs token; functionality restored or
  flow simplified.

## 6. Risks / open decisions

- Auth-adjacent; keep TV pairing invariants intact.

---

**Next step (pending approval):** clarify flow and fix.
