# Triage Plan — Issue 14.1: Watch History Not Populated (Signed-In Web)

**Date:** 2026-10-23 (IST 03-18)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → Issue 14, fault 1
**Branch:** `fix/issue-14-user-reported-faults`
**Status:** ✅ **FIXED 2026-10-23 17:50.** The change recorded in §7 was behaviour-identical to what
it replaced and is retracted in §9. The real cause was **two device identities per browser**; §10 is
the root cause, the fix and the evidence.

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

---

## 10. ROOT CAUSE AND FIX (2026-10-23, 17:50) — 14.1 FIXED

Triage restarted one layer earlier than §9 left it, and the answer is **two device identities per
browser**: the player wrote history under one, and the devices page read the other.

| identity | written by | history (measured 17:20) |
|---|---|---|
| `web_4f30657458814841` | `POST /api/progress`, whose `X-Device-Id` comes from `useDeviceId()` | **12 rows** — newest 15:57 that day (*2001: A Space Odyssey*), real titles |
| `dev_de77b40cf4a45d37` ("Windows PC") | `GET /api/devices`, falling back to `dev_` + SHA-256(ip\|ua) | **0 rows** |

`DeviceService::get_or_create_device_id` accepted only ids beginning `dev_`. The SPA mints `web_…`,
so the header was **discarded** and the server invented a fingerprint device — and the devices page
dutifully showed a current device that had never played anything. Reproduced with a live curl before
the fix: `X-Device-Id: web_4f30657458814841` still answered `current_device_id: dev_60a0c284fae53f44`.

**Second layer: the identity was also being shadowed by a Flask-era cookie.** Flask stamped
`ms_device_id` (max-age 1 year) on every HTML response (`c5ee97d^:app/__init__.py:269-277`), and the
Rust resolver checks the cookie **before** the header. Rust never mints or refreshes that cookie, so
a browser that used the Flask app can keep a stale `dev_…` cookie until 2027 — fixing the prefix
alone would have left the bug in place for exactly the browser that reported it.

**The §7/§9 expression was neither the cause nor the fix.** It stays only because the boolean form
reads better.

### Fix

- `rust/src/services/device_service.rs`
  - `is_client_device_id()`: accept **`dev_` and `web_`**, ASCII body, `<= 64` chars, no separators.
    This is *narrower* than the old check, which accepted any `dev_`-prefixed string.
  - Precedence is now **header → cookie → hash**. The header is the live client's own identity; the
    cookie is legacy. The fallback hash is byte-identical (seed `"{ip}|{ua}"`, SHA-256, first 16 hex),
    so no existing client is re-keyed.
- `web/src/features/devices/DevicesPage.tsx`: sends `X-Device-Id` from `useDeviceId()` on
  `GET /api/devices` and on every mutation (rename, delete, admin calls), so the page asks about the
  same device the player writes to.

No `/api/*` shape changes. The Flutter client cannot be affected: it has no cookie jar and its ids
match `^dev_[0-9a-f]{16}$`.

### Evidence

- **Rust:** `cargo test -- --test-threads=1` — 125 lib tests plus every integration binary,
  **0 failures**; `devices_test` **22/22**, including a new regression test that inserts a `web_`
  device with a history row and asserts it comes back as `current_device_id` **with that history**,
  and a rewritten unit test pinning both id families, header-over-cookie, and the rejected shapes.
- **Web:** **318 tests / 42 files, 0 failures**; `tsc -b` clean; `npm run build` written.
- **Live** (service restarted; binary `17:47:46` newer than the last commit `16:52:55`):
  `GET /api/devices` with `X-Device-Id: web_4f30657458814841` →
  `current_device_id: "web_4f30657458814841"`, **12** history rows, recent *2001: A Space Odyssey*;
  `/devices` renders "THIS BROWSER", "Recent: 2001: A Space Odyssey 0%" and "Watch History 12".
  The 0% is truthful — the newest play is 3 s into an 8,931 s film — not a display fault.
- **Cleanup, approved by the owner:** **374 device rows with no history were deleted** (407 → 33
  rows; every survivor has history). Only `device_watch_history` references `devices` (FK
  `ON DELETE CASCADE`), the deleted rows had no children, and every `user_id` was `NULL`, so no
  ownership was lost. The browser's own row survived with its 12 rows.

### Header consolidation (the other half of the request)

The owner also asked for **Upload Media in the header row**. It is now portalled from `LibraryPage`
into `#header-page-actions`, a slot `AppShell` renders inside the primary nav (the id lives in
`web/src/lib/useHeaderActionsTarget.ts` so the two files cannot drift apart). The label hides below
640 px (icon-only; `aria-label` keeps the accessible name), and the hero is the page's first element
again, so it takes its original tucked variant (`-mt-6 sm:-mt-8 rounded-b-3xl`). Measured in Edge:
at 390 / 768 / 1280 px exactly one Upload control exists, it is inside the slot, and the hero is the
page's first child. No player, upload or PIN-gate code was touched.