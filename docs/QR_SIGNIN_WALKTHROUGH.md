# QR Device Sign-In — Feature & Hardening Walkthrough

**Feature:** OTT-style QR device sign-in for camera-less devices (smart TVs, desktop browsers,
consoles, Fire TV Stick browser) — inspired by the Netflix / YouTube TV activation flows.
**Branch:** `feature/qr-signin-web-tv`
**Backend:** Rust Axum (`rust/src/routes/qr_auth.rs`, `rust/src/services/auth_service.rs`)
**Frontend:** React 19 SPA (`web/src/`)
**Status:** ✅ Delivered, hardened, verified live, deployed

> The feature was implemented in `eb3b8dc` and hardened in the commit directly on top of it.
> This document covers both: what the flow does, and the four defects that a verification pass
> found in it.

---

## 1. Why This Exists

A smart TV, a console, or a desktop browser has no keyboard. Entering an email address and a
password with a D-pad is miserable, and the Google OAuth flow assumes a browser that can run the
consent screen.

The industry answer is an **activation code**: the screen shows a short code and a QR image, the
user types the code (or scans the QR) on a device that *does* have a keyboard, and the first
device signs itself in.

This server now does exactly that, with the addition of a **friendly device name** chosen on the
phone — so the television that just signed in shows up as *"Living Room TV"* in the fleet list
rather than as an anonymous `web_3f04…` browser row.

---

## 2. The Flow

```text
 ┌────────────────────────────┐                    ┌────────────────────────────┐
 │  TV / Browser              │                    │  Phone (has a keyboard)    │
 │                            │                    │                            │
 │  GET /account              │                    │                            │
 │  (unauthenticated)         │                    │                            │
 │    └─ renders QrSignInPanel│                    │                            │
 │         │                  │                    │                            │
 │  POST /api/auth/qr ────────┼──▶ qr_id, code,   │                            │
 │         │                  │    sig, qr_url    │                            │
 │         ▼                  │    (120s TTL)     │                            │
 │  renders QR + 5-char code  │                    │                            │
 │  opens SSE /wait ──────────┼──▶ pending ───────┼─▶  scan QR, or type code  │
 │         │                  │                    │    GET /remotelogin        │
 │         │                  │                    │    POST /api/auth/qr/lookup│
 │         │                  │                    │    POST /api/auth/qr/{id}/ │
 │         │                  │                    │         confirm           │
 │         │                  │◀─── confirmed ─────┼─▶ (sets device_name)      │
 │         ▼                  │                    │                            │
 │  GET /api/auth/qr/{id}/    │                    │                            │
 │      finalize             │                    │                            │
 │    └─ Set-Cookie: session_token=sess_… (30d)    │                            │
 │    └─ 307 → /             │                    │                            │
 └────────────────────────────┘                    └────────────────────────────┘
```

### 2.1 The six endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `POST` | `/api/auth/qr` | none | Create a pair session. Returns `{qr_id, code, sig, expires_at, qr_url, login_url}`. |
| `POST` | `/api/auth/qr/lookup` | **session required** | Resolve a hand-typed 5-char code to its `qr_id`. |
| `GET` | `/api/auth/qr/{id}/wait` | none | Server-Sent Events stream: `data: pending` / `confirmed` / `expired`. |
| `GET` | `/api/auth/qr/{id}/status` | none | JSON polling fallback for SSE-hostile networks. |
| `POST` | `/api/auth/qr/{id}/confirm` | **session required** | The phone authorises the pairing, supplying `device_name`. |
| `GET` | `/api/auth/qr/{id}/finalize` | none | The TV claims the session: issues the cookie and 307-redirects to `/`. |

`lookup` and `confirm` require the *phone* to be signed in. `create`, `wait`, `status` and
`finalize` are the TV side and are unauthenticated by necessity — the TV is not signed in yet.

### 2.2 The database table

`device_pair_sessions`, created by `ensure_schema()` in `rust/src/db.rs`:

| Column | Type | Notes |
|---|---|---|
| `id` | `TEXT` PK | `qr_<64 hex>` — 256 bits from the OS CSPRNG |
| `code` | `TEXT` | 5-char code, unambiguous charset, 25 bits |
| `code_hash` | `TEXT` | SHA-256 of the code |
| `sig` | `TEXT` | HMAC-SHA256 of `qr_id:code`, keyed with `MEDIA_SERVER_SECRET` |
| `user_id` | `BIGINT` FK → `users(id)` `ON DELETE CASCADE` | Bound on confirmation |
| `session_id` | `TEXT` | The 30-day session minted for the TV |
| `device_name` | `TEXT` | The friendly name the phone user chose |
| `confirmed` | `BOOLEAN` | Flips when the phone authorises |
| `expires_at` | `TIMESTAMPTZ` | 2-minute TTL, indexed |
| `created_at` | `TIMESTAMPTZ` | Default `CURRENT_TIMESTAMP` |

Indexes: `idx_device_pair_expires` (on `expires_at`) and `idx_device_pair_code` (on `code`).

### 2.3 The `sig` — what it is for

The QR URL is `…/remotelogin?qr_id=…&code=…&sig=…`. The `sig` is
`HMAC-SHA256(MEDIA_SERVER_SECRET, "qr_id:code")`, so a phone that scanned the QR can confirm
without re-typing the code, and the code cannot be altered in transit without invalidating it.

It is a convenience and an integrity check — **not** the primary secret. The primary secret is
the code itself, and the code's entropy is what the hardening work was about.

---

## 3. The Frontend

| File | Role |
|---|---|
| `web/src/components/QrSignInPanel.tsx` | The TV/browser side. Canvas QR, 5-char code badge, SVG countdown ring, manual URL box, Google / Admin PIN buttons. |
| `web/src/hooks/useQrSession.ts` | The lifecycle: 120 s countdown, SSE subscription, silent rotation on expiry. |
| `web/src/features/remote-login/RemoteLoginPage.tsx` | The phone side, at `/remotelogin`. Isolated from the app shell — no navbar, no footer. |
| `web/src/features/account/AccountPage.tsx` | Hosts the panel when unauthenticated. |
| `web/src/lib/api/account.ts` | `createQrSession`, `lookupQrCode`, `confirmQrSession`. |

### 3.1 The phone-side state machine

```text
loading ──▶ sign-in ──▶ enter-code ──▶ name-device ──▶ success
              (not authed)  (authed,       (code resolved  (paired)
                            no QR params)   or QR scanned)
```

- **QR scan** → `?qr_id&code&sig` are present, so the code is auto-filled and the lookup is skipped.
- **Manual entry** → 5 auto-advancing single-character inputs, paste-friendly, with real-time
  `/lookup` as the user types.
- **Not signed in** → a Google sign-in link that **preserves the QR parameters** through the
  redirect, so the flow resumes where it left off.

---

## 4. The Defects That Shipped With It

The feature was implemented, the Rust integration test passed, and `npm run build` compiled
cleanly. A verification pass found four defects anyway. Two of them are security issues on a
publicly reachable endpoint.

### 4.1 P0 — the pair code had 5 bits of entropy, not 25

`generate_pair_code()` walked a single 64-bit LCG and took `seed % 32` per character:

```rust
let mut seed = (nanos as u64) ^ count ^ rand_pseudo();
for _ in 0..5 {
    code.push(CHARS[(seed as usize) % CHARS.len()] as char);
    seed = seed.wrapping_mul(6_364_136_223_846_793_005)
               .wrapping_add(1_442_695_040_888_963_407);
}
```

The multiplier and the increment are **both odd**. For an LCG mod 2⁶⁴, the low 5 bits of the
next state depend only on the low 5 bits of the current one — so the low 5 bits of *every* step
depend only on the low 5 bits of the *first* step. All five characters are therefore a function
of 5 bits.

**Measured, live, on the running server: 40 sessions produced 15 distinct codes.** The intended
space is 32⁵ = 33,554,432.

This is not a theoretical weakness. `POST /api/auth/qr/lookup` resolves a code to the `qr_id` of a
live, unexpired, unconfirmed pairing session, and `confirm` then accepts that same code. So any
signed-in account — a viewer-role Google login is enough — could try all 32 codes in under a
second, take over another user's active TV pairing, and bind that television to the attacker's
own account.

**Fix.** Draw each character independently from the OS CSPRNG:

```rust
let mut buf = [0u8; 5];
getrandom::getrandom(&mut buf)?;
Ok(buf.iter().map(|b| CHARS[(*b as usize) % CHARS.len()] as char).collect())
```

`byte % 32` is exactly uniform here: the charset is 32 characters and 256 is a multiple of 32,
so there is no modulo bias and no rejection sampling is needed. That reasoning is in a comment,
because it is the obvious reviewer question.

**Verified live: 200 sessions → 200 distinct codes.** In the production table, 204 rows held
204 distinct codes.

### 4.2 P0 — every security token was seeded from the clock

`generate_random_token()` hashed a clock-derived seed:

```rust
let sig = format!("auth:{}:{}:{}:{}", nanos, count, pid, rand_pseudo());
```

`nanos` is a real clock, and `rand_pseudo()` was `nanos_low64 ^ 0x517cc1b727220a95`. The seed
space is therefore bounded by the creation time, and an attacker who can narrow it to about a
second can search it.

That token mints:

- `sess_` — session cookies,
- `ms_` — device tokens,
- the OAuth `state` and `nonce`,
- the PKCE `verifier`,
- and **`qr_` — the `qr_id`**, which is the *only* key to the unauthenticated
  `GET /api/auth/qr/{id}/finalize` endpoint that hands out a 30-day session cookie.

**Fix.** 256 bits from `getrandom`, failing closed: if the random source is unavailable the
request errors rather than minting a guessable secret. The signature became
`Result<String, AppError>`, and the compiler found all eight call sites.

### 4.3 P0 — the pair code and the full `qr_id` were logged in plaintext

```rust
info!("QR: created pair session qr_id={} code={}", qr_id, code);
```

Anyone who can read the service log could claim the paired television's session inside the
2-minute window. The log now carries a 12-hex-character reference — neither the code nor the
full id.

**Verified: both are absent from `logs/rust_api.log`.**

### 4.4 P0 — the frontend suite was broken

`useQrSession` constructed an `EventSource` inside an effect. **jsdom implements no
`EventSource`.** The resulting `ReferenceError` was thrown from inside an effect, which React
treats as fatal for that subtree — so it tore down the entire `AccountPage` tree and failed
*every* assertion in the file, not only the ones about the QR panel.

`web/src/test/setup.ts` is the established home for exactly this kind of stub (it already stubs
`play`, `pause`, `load` and `scrollTo`), and it now stubs `EventSource` too.

A second, independent break: the *"Sign in with Admin PIN"* button was renamed to a bare
*"Admin PIN"* and relocated into the panel, while two assertions expected
`/sign in with admin pin/i`. The accessible name was **restored** — it is also better for
screen readers, and it sits next to a sibling button that reads *"Sign in with Google →"*.

### 4.5 Two behavioural bugs found alongside them

**The QR panel flashed for signed-in users.** It was gated on `!authenticated` alone, and
`authenticated` is `false` for *everyone* while `/api/auth/me` is in flight. So the panel mounted
for signed-in users, flashed a *"Sign in"* card at someone who was already signed in, and fired
`POST /api/auth/qr` — **creating a pair session on the server on every account-page visit**.
Now gated on `!authLoading && !authenticated`.

**StrictMode created two pair sessions per expiry.** The expiry check lived *inside* a
`setSecondsLeft` updater and called `fetchSession()` from there. A state updater must be pure,
and React's StrictMode deliberately double-invokes updaters in development — so every expiry
created two sessions, one of them orphaned. The check now lives in the interval callback, where
side effects belong.

---

## 5. Test-Database Isolation

**The entire Rust integration suite was running against the production `media_server` database.**

Every test built its config with `AppConfig::from_env()`, which falls back to
`postgresql://postgres:postgres@127.0.0.1:5432/media_server` when `MEDIA_SERVER_DATABASE_URL` is
unset — and on this host it is unset. A test that inserted a row and failed before its cleanup
left that row in the live catalog.

`qr_device_auth_flow_test` did exactly that. It inserted `users(google_sub='sub_phone_user')`
with a plain `INSERT` and never removed it, so it **passed on a clean database and then failed
on every subsequent run**:

```
23505 duplicate key value violates unique constraint "users_google_sub_key"
```

### 5.1 The new `rust/src/test_support.rs`

| Function | Purpose |
|---|---|
| `test_config()` | Provisions the dedicated database, redirects `cache_dir` to a temp path, leaves `media_roots` alone so file-based contracts still work. |
| `ensure_test_database(url)` | Creates `media_server_test` if absent (`CREATE DATABASE` cannot run in a transaction block, so it uses a bare connection). |
| `discover_real_media_file(roots)` | Finds a real, probeable video file. |
| `seed_real_media_row(pool, roots)` | Inserts a catalog row for it. |
| `remove_seeded_media_row(pool, name)` | Removes it again. |

Override the database with `MEDIA_SERVER_TEST_DATABASE_URL`. The default is
`postgresql://postgres:postgres@127.0.0.1:5432/media_server_test`.

**The database is isolated; the media roots are not, and must not be.** `ffprobe` has to return
real container and stream values, so the metadata contracts are only meaningful against a real
file. The *metadata* is written to the test database; the *bytes* are the real ones, read-only.

### 5.2 `ensure_schema()` was creating only 7 of the 13 tables

`movies`, `progress`, `devices`, `device_watch_history` and `ip_cache` came only from the
SQLite→PostgreSQL migration script. A fresh database was half-formed: the server booted, created
its own tables, and then failed on the first query that touched the catalog. The isolated test
database made this visible immediately.

Those tables are now created with DDL matching the migrated production tables exactly, so
`CREATE TABLE IF NOT EXISTS` is a no-op against the live database.

### 5.3 Test hygiene rules that came out of it

- A test that inserts rows must use `ON CONFLICT … DO UPDATE` **and** purge at setup **and** have
  an explicit teardown.
- **`Drop` cannot clean a database** — it is synchronous, the database calls are async. The
  teardown is an `async fn` the test calls, and the test then *asserts* the residue count is zero
  rather than trusting the hook.
- **Do not assert against production data.** The scanner reconciliation test used to assert that
  `Oculus.2013.1080p.BluRay.x264.YIFY.mp4` survived — so it broke if that title was ever removed
  from the library. It now owns its fixture.
- **A setup-time purge that is too broad will delete a concurrently running test's rows.** The
  Rust harness runs the tests within a binary in parallel. The pair-session purge is scoped to
  *expired* rows for exactly this reason.

---

## 6. Verification

| Check | Result |
|---|---|
| `cargo test --no-fail-fast -- --test-threads=1` | **exit code 0** — 108 unit tests, 26/26 integration targets |
| `qr_device_auth_flow_test`, run twice consecutively | passes both times (it failed on every re-run before) |
| `npm run test` | **248 passed / 0 failed** (36 files) — was 222 passed / **5 failed** |
| `npm run typecheck` | clean |
| `npm run build` | clean |
| `npm run lint` (oxlint) | exit 0; the two `set-state-in-effect` warnings in `useQrSession.ts` are pre-existing |
| `scripts/probe_android_api.py` | **22/22** per contract |
| Live pair-code entropy | **200 sessions → 200 distinct codes** (was 40 → 15) |
| Production `device_pair_sessions` | 204 rows → **204 distinct codes** |
| Log leak | neither the code nor the full `qr_id` appears in `logs/rust_api.log` |
| Production DB after a full suite run | 0 residue; 33 movies unchanged |

### 6.1 Deployment

Restarted through `scripts\restart_rust_service.bat` (self-elevates via UAC).

| Artefact | Built | Newest source change | Verdict |
|---|---|---|---|
| `rust/target/release/media-server-api.exe` | 10:44:38 | 10:19:59 (`db.rs`) | binary newer ✅ |
| `web/dist/index.html` | 10:41:40 | 10:41:10 (`useQrSession.test.ts`) | bundle newer ✅ |

---

## 7. New Tests

### 7.1 Rust unit tests — `rust/src/services/auth_service.rs`

| Test | Pins |
|---|---|
| `test_pair_code_has_real_entropy` | ≥ 5,000 distinct codes from 10,000 draws, 5 chars, correct charset. **The collapsed generator produced 32** — this test would have caught the original defect. |
| `test_pair_code_characters_are_not_correlated` | Each character position reaches the full 32-character charset, so no shared state word drives them. |
| `test_random_token_is_256_bits_of_unique_material` | 64 hex chars, 1,000 unique tokens. |
| `test_redacted_pair_ref_is_not_the_secret` | The logged reference is not the full id and does not carry the code. |

### 7.2 Frontend — 21 new Vitest tests

| File | Covers |
|---|---|
| `web/src/hooks/useQrSession.test.ts` | Session creation, countdown, SSE subscribe, `confirmed` → navigate to finalize, `expired` → refresh, **exactly one replacement session per expiry** (the StrictMode regression), cleanup on unmount, retry-on-failure. |
| `web/src/components/QrSignInPanel.test.tsx` | Code and URL rendering, QR canvas, Google button gated on `oauthConfigured`, the Admin PIN accessible name, both callbacks, the countdown label. |
| `web/src/features/remote-login/RemoteLoginPage.test.tsx` | Every step of the phone flow: sign-in gate, QR-parameter preservation through the Google redirect, QR-scan skip, manual code → lookup, confirmation, and both failure paths. |

---

## 8. Traps Worth Knowing

- **A state updater must be pure.** The StrictMode double-session bug came from a
  `fetchSession()` call inside `setSecondsLeft`. React double-invokes updaters in development on
  purpose.
- **An error thrown in an effect is fatal for that subtree.** That is why the missing
  `EventSource` failed every assertion in `AccountPage.test.tsx` rather than one.
- **`getrandom` and `url` are already in `Cargo.lock`** (0.2.17 and 2.5.8, pulled in by
  `rand_core`/`ring` and `sqlx-core`/`tower-http`). Adding them as direct dependencies cost no
  additional compilation.
- **`ensure_schema()` runs on every pool creation**, including the test pool, so a fresh test
  database self-provisions.
- **The pair-session sweeper is create-triggered.** It runs inside `create_pair_session`, so a
  burst of sessions is reclaimed on the *next* create, not on a timer. Verified: 204 rows → 2
  after one further create.
- **`create_pair_session` calls the sweeper and ignores its result** (`let _ = …`). A sweep
  failure would be silent. Worth tightening.

---

## 9. Still Open

These are known and deliberately deferred. See the next-actions list in the handoff.

| Item | Note |
|---|---|
| Plaintext `code` at rest | The table stores both `code` and `code_hash`; only the hash is needed for lookup. Needs an `ALTER` on the live table. **Still open.** |
| `get_base_url` trusts `Host` | **Closed 2026-10-20.** `MEDIA_SERVER_PUBLIC_BASE_URL` now takes precedence over the request headers, so the emitted `qr_url` is no longer host-header-injectable. The same applies to the Google OAuth redirect URI. |
| `finalize` is unbound | It is unauthenticated and keyed only on `qr_id`. A per-session secret issued at create time would close it. **Still open.** |
| The QR endpoints are not rate-limited | `/wait` spawns a task plus a PostgreSQL query every 3 s per connection, with no auth and no cap, on a public endpoint. **Still open.** |
| The session cookie has no `Secure` flag | **Closed 2026-10-20, conditionally.** `AuthService::session_cookie()` adds `Secure` only for requests that arrived over TLS. It cannot be unconditional — the LAN path is plain HTTP, and a browser refuses to send a `Secure` cookie over plain HTTP. |
| The pairing signature was keyed by a published constant | **Closed 2026-10-20.** `hmac_pair_code` read `MEDIA_SERVER_SECRET` while the deployment sets `MEDIA_SERVER_SECRET_KEY`, so it was using the literal fallback string published in the source. It now reads either name and falls back to a random process-local key. |
| The origin was reachable over plain HTTP from the internet | **Closed 2026-10-20.** The router's `8000` port forward was removed; only 443 and 80 reach the host. |
