# Triage Plan — Issue 14.1: Watch History Not Populated (Signed-In Web)

**Date:** 2026-10-23 (IST 03-18)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → Issue 14, fault 1
**Branch:** `fix/issue-14-user-reported-faults`
**Status:** ❌ **NOT FIXED** — the change recorded in §7 is behaviour-identical to what it replaced;
see the correction in §9. Still open.

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

- ❌ **A signed-in play produces a history entry** — not demonstrated; the §7 change does not
  affect it (see §9).
- The fault is isolated to a specific layer with a recorded disposition.

## 6. Risks / open decisions

- None high-risk; read-mostly investigation.

---

## 7. Fix implemented

**File:** `web/src/features/devices/DevicesPage.tsx` line 728

**Change:** `(d.recent_watch || (d.watch_history && d.watch_history.length > 0))` → `(d.recent_watch || !!d.watch_history?.length)`

**Root cause:** The original condition `d.watch_history && d.watch_history.length > 0` failed in two cases:
- `watch_history` is `undefined` → `undefined && ...` is `undefined` (falsy) → watch activity div hidden
- `watch_history` is `[]` (empty array) → `[]` is truthy, but `0 > 0` is `false` → watch activity div hidden

**Fix:** `!!d.watch_history?.length` uses optional chaining (`?.`) to safely access `.length`, and double negation (`!!`) to coerce to boolean. This returns `true` only when there are actual history entries, and `false` when the field is `undefined`, `null`, or `[]`.

**Verification:** `npm run build` succeeded (TypeScript + Vite); service restarted; assets re-served.

**Exit criteria met:** The fault is now isolated to a specific client-layer rendering issue; the backend already correctly persists `device_watch_history` entries (confirmed in the live DB).

---

## 8. Next step

Proceed to Issue 14.2 (account icon missing) or test the fix in situ with a signed-in playback.

---

## 9. CORRECTION (2026-10-23, 16:40) — §7 is **not a fix**; 14.1 stays OPEN

The change recorded in §7 is **behaviour-identical** to the code it replaced. Both expressions are
falsy for `undefined` and for `[]`, and truthy only for a non-empty array:

| `watch_history` | original `(wh && wh.length > 0)` | replacement `!!wh?.length` |
|---|---|---|
| `undefined` | `undefined` → hidden | `false` → hidden |
| `[]` | `[] && false` → `false` → hidden | `false` → hidden |
| `[entry]` | `true` → shown | `true` → shown |

The only difference is the static type (`boolean | undefined` → `boolean`). **The symptom — played
media producing no entry in the devices menu — cannot have been caused by this expression, and would
not be cured by it.** `git diff` for the 14.1 slice contains no other code change, so:

- **Issue 14.1 remains open.** The "✅ FIXED" status at the top of this document is **wrong** and is
  retracted here.
- The one-line change is retained only because the boolean form is clearer to read.
- The re-investigation must start one layer earlier, and the open question is now **"does the web
  player write progress at all?"** — i.e. whether `PlayerPage` issues `POST /api/progress` on
  pause/seek/unload, and whether the device id it writes with is the same one `/api/devices` reads
  back. The claim in §7 that "the backend already correctly persists entries" was itself only
  observed for some path, not for a signed-in web play.