# 2026-10-23 03:03 IST — Access control Phase 3: admin oversight of accounts, devices & watch history

Agent: opencode (DeepSeek V4.1 Flash)
Scope: Phase 3 of the access-control backlog — implemented, tested, deployed and live-verified.
Commits: **`753c901`** (3.1 read model), **`2e4109e`** (3.2 mutations), **`2781c51`** (3.3 web),
and the docs/deploy commit for this handoff. Plan:
[`docs/ACCESS_CONTROL_PHASE_3_PLAN.md`](../docs/ACCESS_CONTROL_PHASE_3_PLAN.md) (status DELIVERED,
delivery record in §8).

## Objective

Phase 2 made ownership and history *sticky*: a device is claimed once and never reassigned, and a
watch-history row is never editable. Phase 3 is the supported way for an admin to correct both —
see which account owns each device, list accounts with their footprint, move a device between
accounts, and delete watch history (one entry or a whole device).

Owner decisions recorded in the plan: **D1** = delete one entry *and* clear a device (no position
editing), **D2** = include ownership reassignment, **D3** = extend `/devices` rather than build a
separate `/admin/accounts` page.

The media library itself stays public. Phase 3 scopes *oversight*, not media, and adds no new
visibility boundary.

## What changed

### Read model — `rust/src/services/device_service.rs`

- `DeviceOwner {id, email, name, role}` and `DeviceDetail.owner: Option<DeviceOwner>`.
- The device query `LEFT JOIN users` for attribution and maps `owner` **only when `is_admin`**;
  every other caller gets `null`. The Phase 2 WHERE-clause scoping is untouched — attribution must
  not widen visibility.
- `GET /api/devices` therefore stays shape-compatible: one additive key.

### Routes — `rust/src/routes/admin.rs`, `rust/src/lib.rs`

- `GET /api/admin/users` — admin-gated (Admin PIN **or** admin session); returns
  `id, email, name, role, created_at, last_login_at, device_count, history_count`.
  Counts are computed in SQL, `google_sub` is never selected, and a viewer/anonymous caller gets
  **403**, not an empty list.
- `POST /api/admin/devices/assign` — `{device_id, user_id|null}`. The one explicit exception to
  claim-once. `user_id` **absent** → 400; explicit `null` → unassign; a number → assign. Unknown
  device or user → 404. The automatic claim stays `UPDATE … WHERE user_id IS NULL`.
  The field is `Option<Option<i64>>` with `#[serde(default, deserialize_with = "…")]` and
  `Option::<i64>::deserialize(d).map(Some)`: without that, serde deserializes JSON `null` as the
  outer `None`, making "unassign" indistinguishable from "field missing" (found by
  `test_assign_sets_moves_and_clears_device_ownership`).
- `POST /api/admin/devices/history/delete` — `{device_id, filename?}`. A filename deletes one row
  and a miss is a 404; omitting it clears the device (idempotent, `deleted: 0`). Unknown device →
  404. It deletes from `device_watch_history` only — no media file is read, moved or deleted, and
  the legacy filename-keyed `progress` table is not touched.
- Both mutations are admin-gated and answer 403 to viewer and anonymous callers.

### Web — `web/src/features/devices/DevicesPage.tsx` (+ `.test.tsx`)

- Admin identity = signed-in `role === 'admin'` **or** stored PIN **or** session PIN unlock, but
  every oversight surface renders only after `GET /api/admin/users` answers **200**. A stale PIN
  therefore hides the controls rather than offering actions the server will refuse.
- Accounts panel (name/email, role badge, device/history counts), owner badges on each device,
  owner filter, portaled reassign modal (accounts + Unassigned, with the "history moves with the
  device" warning), **Clear history** with a named confirmation, and per-entry delete inside the
  history modal.
- An admin *session* no longer sees the "Unlock Fleet Telemetry" PIN prompt; lock/unlock remains for
  the PIN-only path. All new modals portal to `document.body`.
- Non-admin rendering is unchanged, and `useOptionalAuth()` keeps the page working outside
  `AuthProvider` (existing tests unaffected).

### Deliberately unchanged

- Claim-once automatic ownership (`WHERE user_id IS NULL`), Phase 2 list/history scoping, and the
  rename/delete authorisation rules.
- `progress` stays global (tracked debt); the scoped history is `device_watch_history`.
- `/api/devices` fields stay additive only; the Flutter contract is unchanged.
- Not in scope: position editing, account create/delete, role changes, library gating,
  account-list pagination, audit log.

## Tests

- **Rust: 343 passed, 0 failed across 33 suites** (`--test-threads=1`; redirected log, `EXIT=0`).
  The new `rust/tests/admin_oversight_test.rs` holds 7 tests: admin sees owner attribution and a
  viewer's payload carries no other account's email; both PIN and admin session can list accounts
  with correct counts; viewer and anonymous get 403; assign sets/moves/clears (missing `user_id` =
  400, unknown device/user = 404); history delete removes one entry, clears a device, is idempotent
  and 404s on a miss; the refusal matrix asserts the row is **unchanged** after a 403; and the last
  test asserts zero oversight residue. Runs against `media_server_test` via
  `test_support::test_config()`.
- **Web: 42 files / 314 tests** (5 new: attribution + accounts render, reassign request body,
  clear-history confirmation/body, single-entry delete, non-admin sees no controls and never calls
  `/api/admin/users`). `npm run build` clean (tsc + vite).

## Live verification

Temporary rows: users `phase3.live.a@example.test` (viewer) and `phase3.live.b@example.test`
(admin), device `dev_live_phase3` owned by A with 2 history entries, one viewer and one admin
session. Every check passed, then teardown left **`0/0/0/0`** residue (users/devices/history/
sessions) and production at **403 devices / 3 users**, unchanged.

- anonymous and viewer `GET /api/admin/users` → 403; admin → 200, both accounts, correct
  `device_count`/`history_count`, no `google_sub`;
- admin `GET /api/devices` → `owner.email` = A; viewer `GET /api/devices` with
  `X-Device-Id: dev_live_phase3` → `owner: null` and **no account email anywhere in the raw JSON**;
- viewer and anonymous `POST assign` → 403, DB owner still A; viewer and anonymous
  `POST history/delete` → 403, 2 entries still present;
- assign A→B → 200, DB owner B, admin payload reflects B; `null` → 200, DB NULL; missing
  `user_id` → 400; unknown device and unknown user → 404 with ownership still NULL;
- delete one entry → `deleted: 1`, sibling intact; unknown filename → 404, nothing deleted;
  clear device → `deleted: 1`; clear again → `deleted: 0`; unknown device → 404.

`python scripts/probe_android_api.py` → **22/22 per contract** (0 HTML pages requested).

## Deploy

`scripts/restart_rust_service.ps1` (elevated), exit 0: PG reachable → service stopped → release
build `1m 52s` → service Running → SPA `/` 200 and `/api/movies` 200 → "Service restarted and
healthy". Release binary `LastWriteTime` **2026-10-23 03:00:14**, later than the newest source
commit at **02:58:07**; `/health` reports `status: healthy, engine: rust`. No schema migration was
required.

The site is briefly unavailable during that stop→build→start window; it returned before the live
proof began.

## Docs

- `AGENTS.md`: the Phase 3 entry under access control and a new invariants section, *Admin oversight
  of accounts, devices & watch history* (attribution boundary, the admin probe, claim-once
  exception, history-only deletion, real refusals, server-confirmed UI gate).
- `docs/PROJECT_STATUS.md`: recent-work section retitled **Phases 1–3** with the Phase 3 paragraph
  and verification line; roadmap item updated (nothing remains in this phase).
- `docs/ACCESS_CONTROL_PHASE_3_PLAN.md`: status DELIVERED and §8 delivery record.
- This handoff; Obsidian `Decisions Log` and `Verification Log` entries.

## Notes for the next agent

- **Verify a deploy by artefact timestamp.** `/health` only proves *some* build is running.
- `x-device-id` is honoured only when the id begins **`dev_`** (`DeviceService::resolve_device_id`);
  a live proof targeting a specific device must use that prefix or it will address a hashed id.
- `psql -c "... RETURNING id"` prints the value **and** the `INSERT 0 1` tag. A script reading it as
  a scalar must take the first line (the harness does).
- **Do not weaken the double-option deserializer** into `Option<i64>`: `null` and absent would
  collapse and an explicit unassign would silently 400.
- The web's oversight gate is server confirmation, not the local role/PIN flag. Keep it that way:
  it is what makes a stale PIN harmless.
- No audit trail yet — mutations are visible only in the service log. Acceptable while one person
  holds the PIN; revisit if that changes.

## Next

Nothing is pending in the access-control backlog. The media library remains intentionally public;
gating it would break DLNA, cast and device tokens. Parked items are unchanged (`progress` scoping,
OpenSubtitles automation, off-host backups, Cloudflare token rotation).
