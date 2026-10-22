# Triage Plan — Issue 14: User-Reported Web / Devices / Playback Faults

**Date:** 2026-10-23 (IST 03-18)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → **Issue 14**
**Branch:** `fix/issue-14-user-reported-faults`

---

## 1. Objective

Triage the six faults the owner reported immediately after the 2026-10-23 Google sign-in outage
was resolved, and produce a fix sequence. **No fix is being implemented in this pass** — this plan
documents what was reported, what is known, what is uncertain, and in what order to attack each.

## 2. Reported faults (recap)

1. **Watch history not populated** (signed-in web, after playing media → nothing listed in the
   devices menu).
2. **Account icon missing** across pages (not through all pages).
3. **Playback stuck at 0:00** (*2001: A Space Odyssey*); sometimes after trying other media and
   returning, it plays — behaviour consistency uncertain.
4. **QR code unscannable** in the signed-in devices-menu state (cropped / not fully displayed).
5. **Header "Sign in" → Google only**, no QR option shown; QR should be disabled only in the TV
   variant.
6. **Add-device flow**: name → QR code + URL + token; owner questions (what to do with QR, URL
   non-functional, where token goes, why it exists when QR login is handled).

## 3. Scope

- **In scope:** web-client UX for the six faults; playback client behaviour; TV-vs-web QR gating.
- **Out of scope (for this triage):** backend behaviour already fixed (sign-in allowlist); Flutter
  device behaviour beyond the add-device QR/URL/token questions; Google OAuth configuration.

## 4. Exit criteria (triage)

- Each of the six faults has a written disposition: *reproduced → fix next*, *reported → needs
  repro*, or *cannot reproduce / needs more info*.
- A prioritized fix sequence with dependencies called out.

## 5. Risks

- Playback faults touch the **player invariants** (seeking, container isolation, modal portal,
  viewports) — avoid broad rewrites; fix narrowly.
- Auth/menu faults touch the `/api/*` contract surface — must not change `/api/*` shapes for the
  Flutter client; the Android probe gate (`scripts/probe_android_api.py`) must stay 22/22.
- QR/TV gating changes risk breaking the QR pairing invariants already proven (pair code entropy,
  token claims).

## 6. Open decisions (owner to make)

1. Should watch history be sourced from `device_watch_history`, `progress`, or both, per device?
2. What is the intended playback fix for the 0:00 stall — autoplay, HLS direct-play, or both?
3. Should the add-device QR/URL/token flow be unified with the existing pairing-token flow, or
   kept as a separate path?
4. Should the header account affordance be restored on all pages, and if so via the shared header
   component?

## 7. Dispositions (initial, for the triage conversation)

| # | Fault | Initial disposition |
|---|---|---|
| 1 | Watch history not populated | **Needs live signed-in repro**; likely progress-source/scoping. |
| 2 | Account icon missing | **Needs page-by-page check** against the shared header. |
| 3 | Playback stuck at 0:00 | **Needs repro** (autoplay vs manual; direct vs HLS). |
| 4 | QR cropped | **Needs layout repro** in signed-in state. |
| 5 | Sign-in menu options | **Needs UI check** of header auth menu + TV variant. |
| 6 | Add-device flow | **UX/flow triage** — likely supersede or clarify vs existing pairing-token flow. |

---

**Next step (pending this plan's approval):** run the live repros, then fix in the order above.
