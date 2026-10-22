# 2026-10-23 02:27 IST — Access control Phase 2: per-user device ownership & watch-history scoping

Agent: opencode (DeepSeek V4.1 Flash)
Scope: Phase 2 of the access-control backlog — implemented, tested, deployed and live-verified.
Commit: **`7bfe34c`** — "feat(devices): per-user device ownership and scoped watch history (access
control Phase 2)", 2026-10-23 02:27:19 IST. Working tree clean at handoff time. Phase 1 was
`f9df666` (docs `6111ae5`).

## Objective

Phase 2 of the access-control work: a device belongs to an account, the device list and its
embedded watch history are scoped per user, and renaming/deleting a device follows ownership.
Phase 1 (admin bootstrap via `MEDIA_SERVER_ADMIN_EMAILS` + upload gating) landed at `6111ae5`.

The media library itself stays public — this scopes *devices*, not media. Gating the library would
break DLNA, cast and device tokens.

## What changed

### Schema — `rust/src/db.rs`

- `devices.user_id BIGINT REFERENCES users(id) ON DELETE SET NULL` (additive, nullable) plus
  `idx_devices_user`.
- `NULL` means unowned: guests, and every row written before Phase 2. **No backfill, no row
  rewritten** — the migration is the `ADD COLUMN` alone, so it is instant and safe on the 403-row
  production table.
- `SET NULL`, never `CASCADE`: deleting an account unlinks its devices instead of deleting the
  physical client's row and (through the history FK) its watch history.

### Service — `rust/src/services/device_service.rs`

- `get_all_devices(pool, current_device_id, caller_user_id, is_admin, …)` — the list is scoped **in
  SQL**: admin → all; signed-in → `user_id = caller OR device_id = current`; anonymous →
  `device_id = current`. The Phase 1 `devices.retain(|d| d.is_current)` for signed-in callers is
  gone (it hid a user's other devices).
- Watch history is filtered to **owned + unowned** devices. A device owned by somebody else is
  still *listed* when it is the caller's current device, but its history is **empty**.
- `claim_device_for_user` — one conditional `UPDATE … WHERE user_id IS NULL`, so the first signed-in
  devices request wins atomically and a second account on the same browser cannot take the device
  over. Never reassigns.
- `device_owned_by` — the read side used by rename/delete.

### Routes — `rust/src/routes/devices.rs`

- `resolve_and_claim()` resolves the signed-in identity and claims the request's device when unowned.
- Claim points: `GET /api/devices`, `/api/devices/heartbeat`, `/api/devices/client-hints`, rename,
  delete. (`progress` is deliberately untouched — see below.)
- `list_devices_handler` passes `caller_user_id`.
- Rename/delete are allowed when admin, when the target is the current device, or when the caller
  owns it; the 403 text is now "…your current device or one you own."

### Deliberately unchanged

- `progress` (legacy filename-keyed table) stays global — approved tracked debt. It is only consulted
  when a request carries no device id; the scoped history is `device_watch_history`.
- `/api/devices` response shape is unchanged (Flutter contract): scoping changes *which* rows, not
  which fields.
- QR finalize untouched; the waiting device is claimed by its next signed-in devices request.

### Tests — `rust/tests/devices_test.rs` (21 total, +4)

- `test_signed_in_user_sees_only_their_devices_and_history`
- `test_owner_can_rename_a_device_they_are_not_using`
- `test_other_user_cannot_rename_or_delete_my_device`
- `test_first_signed_in_request_claims_an_unowned_device_once` (also asserts a shared device owned by
  another account is listed but its history is empty, and that ownership is not stolen)
- `cleanup()` and the residue test extended to the namespaced users/sessions; test users/sessions use
  `*_phase2_test` names so they can never collide with real accounts.

## Verification

- Full Rust suite: **123 unit + every integration suite, 0 failures** (`--test-threads=1`), and
  `devices_test` **21/21** re-run after the last edit.
- Web: `npm run test` **42 files / 309 tests passed**; `npm run build` succeeded.
- Deploy: `scripts/restart_rust_service.ps1` → stop, incremental release build **25.54 s**, start,
  probes `SPA 200`, `/api/movies 200`.
- **Artefact check, not just health:** binary `LastWriteTime` **2026-10-23 02:23:31** (process start
  02:23:33) vs last commit **2026-10-23 01:26:34** → the new build is live.
- Schema live: `user_id bigint nullable=YES`, FK `devices_user_id_fkey on_delete=n` (SET NULL),
  index `idx_devices_user` present.
- Live scoping proof (temporary namespaced users A/B, devices owned explicitly and **verified in the
  DB before any request**):
  - anonymous, current=A → **1** device (own)
  - A, current=A → **1** device, history 0
  - A, current=B → **2** devices (B listed as current + A's own), **B's history 0**
  - B, current=B → **1** device, **history 1** (the same row A could not see)
  - A renames/deletes B's device → **403**, row and name unchanged, owner unchanged
  - A renames own device → **200**
  - admin PIN → **404** devices (403 pre-existing + probe rows); signed-in admin session → all
- Cleanup: residue **0** devices/users/sessions/history; production back to **403 devices /
  0 owned / 3 users**.
- Flutter contract gate: `python scripts/probe_android_api.py` → **all 22 endpoints per contract**.

### Gotcha worth remembering (cost ~15 minutes of false alarm)

`psql -c "stmt1; stmt2; stmt3"` is **one implicit transaction**: the third statement failed
(`completed` is `smallint`, I passed `false`) and rolled back the two `INSERT INTO devices` above it.
The devices were then auto-created unowned by the heartbeat and legitimately claimed by the first
caller — which looked exactly like a scoping bug ("A can see B's history and rename B's device").
The application was correct; the fixture was not. **Always confirm the fixture landed in the DB
before asserting on application behaviour**, and use one `-c` per statement in live smoke scripts.

## Build-environment note (cost ~10 minutes this session)

This shell is not a Developer PowerShell. `link.exe` resolves to `C:\msys64\usr\bin\link.exe` and
the Windows SDK lives at the non-default `D:\WindowsKits\10\`. `cargo check` works (no link step);
`cargo test` / `cargo build` fail. Use `scripts\cargo.bat` — it sets exactly the right MSVC + SDK
`PATH`/`LIB`/`INCLUDE` (`scripts\cargo.bat test --manifest-path rust/Cargo.toml -- --test-threads=1`).

Also: the release exe is held by the running service, so a plain `cargo build --release` fails with
`failed to remove file … Access is denied (os error 5)`. That is why `restart_rust_service.ps1`
stops the service first and rebuilds inside the same run.

## Invariants and docs written

- `AGENTS.md`: new **Device ownership & watch-history scoping (Phase 2)** section (claim-once,
  SQL-side scoping, history follows ownership not visibility, 403 must leave the row intact,
  `progress` stays global, Flutter shape unchanged); the auth backlog item now reads **Phases 1–2
  done** with Phase 3 remaining.
- `docs/PROJECT_STATUS.md` item 2 updated with the same status.
- `docs/PHASE_C5_SLICE_2_DEVICES_PLAN.md` carries a "superseded in part" banner so its old
  current-device-only 403 rule is not mistaken for current behaviour.

## Next moves

1. **Phase 3** — admin UI to view and modify any account's devices and watch history. The backend
   already returns everything for an admin (PIN or admin session); only the surface is missing.
2. Tracked debt: `progress` is still global; shared-device ownership transfer is a deliberate
   non-feature (first owner wins, never reassigned).
3. Pre-existing warnings left alone: duplicate `#[test]` attributes in `cast_control.rs`, unused
   `sha2::Sha256` import in `auth_service.rs`.
