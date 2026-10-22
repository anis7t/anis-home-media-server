# Triage Plan — Issue 14.1: Watch History Not Populated (Signed-In Web)

**Date:** 2026-10-23 (IST 03-18)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → Issue 14, fault 1
**Branch:** `fix/issue-14-user-reported-faults`

---

## 1. Fault

While signed in on the web browser (post-2026-10-23 sign-in restoration) and after playing media,
**no played entry was listed in the devices menu** — i.e. the watch history did not reflect the
playback just performed.

## 2. Context

- Sign-in was restored on 2026-10-23 (stale allowlist row cleared; open sign-in policy; allowlist
  endpoints hardened admin-only).
- Watch history is a first-class feature (Phase 3/4): `GET /api/devices` embeds `watch_history`
  per device; `POST /api/progress` reports progress; the DevicesPage renders a watch-history
  drawer/list.

## 3. Hypotheses

1. The web player's progress write path (`POST /api/progress`) is not firing or is failing silently.
2. The device-watch-history is keyed by a device identifier the browser client does not resolve to
   the same device the history is read back for.
3. The history list rendering is gated on something that is false in the signed-in state (e.g. auth
   load state, selected device).

## 4. Verification approach

- Play a title in the signed-in web browser; then inspect `device_watch_history` and legacy
  `progress` rows for the user/device via psql.
- Check the DevicesPage rendering conditions against the observed state.

## 5. Exit criteria

- A signed-in play produces a history entry; or the fault is isolated to a specific layer with a
  recorded disposition.

## 6. Risks / open decisions

- None high-risk; read-mostly investigation.

---

**Next step (pending approval):** run the live repro, then fix at the identified layer.
