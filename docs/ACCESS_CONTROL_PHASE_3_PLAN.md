# Access Control Phase 3 — Admin Oversight of Accounts, Devices and Watch History

**Status:** APPROVED 2026-10-23 — proceeding slice by slice (D1 = delete entry + clear device,
D2 = include reassignment, D3 = extend `/devices`).
**Predecessors:** Phase 1 `f9df666` (admin bootstrap, upload gating, docs `6111ae5`);
Phase 2 `7bfe34c` (per-user device ownership, scoped list and watch history).
**Invariants it must not break:** the *Device ownership & watch-history scoping (Phase 2)* and
*Admin authorisation invariants* sections of `AGENTS.md`, and the Flutter `/api/*` contract
(`scripts/probe_android_api.py`).

---

## 1. Why this phase exists

Phase 2 gave every device an owner and scoped the list and its history, but it deliberately made two
states **sticky**:

- **Ownership is claimed by the first signed-in devices request and never reassigned.** If a guest
  uses a browser before its real owner signs in, the device stays unowned; if the wrong account signs
  in first, the device — and the history recorded from it — belongs to that account from then on.
- **Watch history is never editable.** A mistaken play, a test recording, or another person's viewing
  on a shared device can only be removed with `psql`.

Admins (Admin PIN or admin session) already receive every device and every history row from
`GET /api/devices`. What is missing is *attribution* (whose device is this?), an *account list*, and
a supported way to correct the two states above. That is Phase 3: **oversight, not new scoping**.

## 2. Scope

### In scope

1. **Owner attribution (read).** `GET /api/devices` gains an additive `owner` object per device:
   `{ "id": 1, "email": "...", "name": "...", "role": "admin" }`, or `null` when the device is
   unowned. Populated **only for admin callers**; every non-admin response carries `owner: null`,
   because a viewer has no business reading other accounts' addresses.
2. **Account list (read).** `GET /api/admin/users` — admin-gated — returns every account with
   `id, email, name, role, created_at, last_login_at, device_count, history_count`. Deliberately no
   `google_sub`: it is an identity key the UI never needs.
3. **Ownership reassignment (write).** `POST /api/admin/devices/assign`
   `{ "device_id": "...", "user_id": 3 | null }` — the one explicit exception to "claim once, never
   reassign". Admin-gated, validates the device and (when set) the user.
4. **Watch-history deletion (write).** `POST /api/admin/devices/history/delete`
   `{ "device_id": "...", "filename": "..." }` deletes one entry; omitting `filename` clears that
   device's history. Returns the number of rows deleted.
5. **Web admin view.** On `/devices`, for admins only: an owner badge per device (`Unassigned` when
   null), grouping/filtering by account, an Accounts panel with per-account counts, a **Reassign
   owner** selector, and a **Clear history** action with a confirmation that names the device and
   says what is removed. The non-admin view is unchanged.
6. **Tests and docs.** Rust integration tests for every rule and every refusal; Vitest coverage for
   the new UI states; `AGENTS.md` Phase 3 invariants; `PROJECT_STATUS.md`; handoff.

### Out of scope (deliberate)

- **Editing watch positions/percentages.** Deleting the entry (so the title reappears unwatched) is
  the supported correction; arbitrary position edits are not a product need.
- **Account administration** — creating, deleting or re-roling accounts. Roles come from
  `MEDIA_SERVER_ADMIN_EMAILS` at sign-in; Phase 3 reads identities, it does not administer them.
- **Gating the media library.** It stays public: DLNA, cast and device tokens depend on it.
- **Scoping the legacy `progress` table.** Still global, still tracked debt (Phase 2 decision).
- **Pagination/search on the account list.** Three accounts today; add it when the count makes it
  real.
- **An audit log of admin mutations.** Accepted risk for a single-owner deployment; listed under
  Risks as a follow-up.

## 3. Design

### 3.1 Read model

`DeviceDetail` (`rust/src/services/device_service.rs`) gains:

```rust
pub struct DeviceOwner {
    pub id: i64,
    pub email: String,
    pub name: Option<String>,
    pub role: String,
}
// on DeviceDetail:
pub owner: Option<DeviceOwner>,
```

The devices query gains a `LEFT JOIN users u ON u.id = d.user_id` selecting `u.id, u.email, u.name,
u.role`; the mapping fills `owner` **only when `is_admin`**, so a viewer's payload is byte-shape
compatible with today apart from `owner: null`. The WHERE clause is untouched — this is an
attribution change, not a scoping change, and the Phase 2 tests must pass unchanged.

`GET /api/admin/users` (in `rust/src/routes/admin.rs`, alongside `/status`, `/verify`, `/pin`):

```json
{ "users": [ { "id": 1, "email": "...", "name": "...", "role": "admin",
               "created_at": "...", "last_login_at": "...",
               "device_count": 2, "history_count": 14 } ] }
```

Counts are `LEFT JOIN` aggregates over `devices` and `device_watch_history`; one query, ordered by
`created_at`. `null` last login is omitted as `null`, not `""`.

### 3.2 Mutations

| Route | Body | Effect | Refusals |
|---|---|---|---|
| `POST /api/admin/devices/assign` | `{device_id, user_id \| null}` | sets/clears `devices.user_id` | 403 non-admin; 404 unknown device; 404 unknown user |
| `POST /api/admin/devices/history/delete` | `{device_id, filename?}` | deletes 1 row, or all rows for the device | 403 non-admin; 404 unknown device; 404 nothing matched |

Both are gated with `AuthService::is_admin_authorized(&pool, &headers, body_pin)` — the same call
`/api/scan`, `/api/storage/*` and upload use, so **PIN and admin session both work** and a viewer
session is refused. They are destructive-but-reversible states, never files: no media file is read,
moved or deleted; `device_watch_history` has `ON DELETE CASCADE` from `devices` but nothing here
deletes a device.

Reassignment must **not** weaken the automatic claim: `claim_device_for_user` stays
`UPDATE ... WHERE user_id IS NULL`. The new route is an explicit human action, and the confirmation
in the UI says that the history moves with the device, because it does.

### 3.3 Web

- `DevicesPage` learns `useAuth().role` and treats `role === 'admin' || isFleetUnlocked ||
  hasStoredPin` as admin — the same rule `ManagePage` and `TranscodeDashboardPage` use. The controls
  additionally require that the response actually carried owner data, so the UI never offers an
  action the server will refuse.
- Each device card gains an owner badge (`owner.name || owner.email`, or `Unassigned`) and an
  account filter in the existing filter row.
- A new Accounts section (rendered only for admins) lists accounts with `role`, device count and
  history count.
- Reassign: a `<select>` of accounts plus `Unassigned`, posting `/api/admin/devices/assign`.
- Clear history: a button per device opening the existing portal-modal pattern, naming the device
  and the number of entries, then posting `/api/admin/devices/history/delete` with no filename.
- Every modal is portaled to `document.body` per the player invariant; the page's `fadeIn` animation
  already ends at `transform: none`.

### 3.4 Contract safety

`/api/devices` stays additive (a new key only), so the Flutter client and `probe_android_api.py` are
unaffected. The new admin routes are outside the Flutter surface. No schema change is required.

## 4. Exit criteria

1. **Rust green**: `cargo test --manifest-path rust/Cargo.toml -- --test-threads=1`, with new tests:
   admin sees owners / viewer's payload has `owner: null`; `/api/admin/users` lists accounts with
   correct counts under both PIN and admin session; assign sets and clears; history delete removes
   one entry and clears a device; **each new route is 403 for a viewer session and for anonymous**;
   no residue after the suite.
2. **Web green**: `npm run test` with new Vitest cases (owner badge, accounts panel, reassign body,
   clear-history confirmation, non-admin sees no controls) and `npm run build` succeeds.
3. **Live proof** on temporary namespaced rows, cleaned up afterwards: admin PIN **and** admin
   session both see owners and the account list; a viewer's `/api/devices` JSON contains no other
   account's email; assign moves a device A→B and back to unowned; clear-history empties one device
   and leaves the other's intact; every mutation refuses viewer/anonymous with 403.
4. **Flutter gate**: `python scripts/probe_android_api.py` → 22/22.
5. **Deploy**: binary `LastWriteTime` after the newest `rust/src` change; service `Running`;
   `/health` and SPA 200; no schema migration expected or applied.
6. **Docs**: `AGENTS.md` Phase 3 invariant block; `PROJECT_STATUS.md` item updated to "Phases 1–3
   done"; handoff with commit, build-env note and the live matrix; this plan marked delivered.

## 5. Risks

- **Email disclosure is the sharp edge.** One misplaced field and every signed-in viewer can read
  the household's addresses. Mitigations: populate `owner` only under `is_admin`; assert it in Rust
  tests *and* in the live smoke by reading the raw JSON; gate the UI on returned data, not on the
  local role flag alone.
- **Destructive history deletion.** Mitigations: the request names device and filename; the bulk
  form is explicit; the confirmation names the device; the response reports the count. There is no
  "delete all history for all devices" action.
- **Reassignment strands history with the wrong account.** That is inherent — ownership is what
  scopes history — so the confirmation must say so, and the live proof must move a device and verify
  the history moves with it.
- **A scoping regression hidden inside an attribution change.** The owner join must not alter the
  WHERE clause; the Phase 2 tests (`test_signed_in_user_sees_only_their_devices_and_history`,
  `test_other_user_cannot_rename_or_delete_my_device`, `test_first_signed_in_request_claims_an_unowned_device_once`)
  must stay green unchanged.
- **Admin surface creep.** Every new route is admin-gated and tested for 403 with a viewer session
  *and* anonymous — a viewer that receives an empty list instead of 403 is a failure.
- **No audit trail.** Mutations are visible only in the service log. Accepted for now; a follow-up
  if multiple people ever hold the PIN.
- **PIN semantics.** A viewer who knows the Admin PIN is an admin — that is the existing product
  rule, not something Phase 3 changes.

## 6. Open decisions

| # | Decision | Recommended |
|---|---|---|
| D1 | Watch-history editing: delete one entry **and** clear a device (recommended); delete one entry only; or also edit positions | delete + clear |
| D2 | Include ownership reassignment, or keep ownership view-only | include |
| D3 | Put the admin view on the existing `/devices` page, or build a separate `/admin/accounts` route | extend `/devices` |

**Resolved 2026-10-23 (owner):** D1 = **delete one entry and clear a device** (no position editing);
D2 = **include reassignment**; D3 = **extend `/devices`**.

## 7. Slices (each independently verifiable)

| Slice | Deliverable | Verification |
|---|---|---|
| 3.1 | Read model: `owner` on `/api/devices`, `GET /api/admin/users` | Rust tests: admin vs viewer payload; counts; 403s |
| 3.2 | Mutations: assign, history delete | Rust tests: set/clear, one/clear, 403s, residue |
| 3.3 | Web admin view: badges, filter, Accounts panel, reassign, clear history | Vitest + build; manual visual check |
| 3.4 | Live verification, docs, deploy, handoff | Live matrix on temp rows; probe 22/22; binary timestamp |

Each slice is presented for approval before it is implemented, per `AGENTS.md` §0.1.
