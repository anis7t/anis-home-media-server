# Security remediation batch

- **Date:** 2026-10-23 00:39 IST
- **Agent:** opencode (DeepSeek V4.1 Flash)
- **Scope:** the four items from the security briefing, worked in the requested order.
- **Status:** all four shipped, verified, deployed. Working tree clean at `d184283`.

## Commits

| Commit | Item |
| --- | --- |
| `a6fd587` | Bump vitest to 4.1.12 (two moderate `@vitest/mocker` CVEs) |
| `8258db7` | Bind `GET /api/auth/qr/{id}/finalize` to the waiting device |
| `cec124d` | Rate-limit every QR route; cap concurrent SSE streams |
| `d184283` | Drop the plaintext pair-code column; hash-only lookup/compare |

## 1. Vitest CVEs (`a6fd587`)

`@vitest/mocker` 4.1.11 carried two moderate advisories (manual-mock registration
code injection, Windows backslash traversal of the redirect allowlist). Both are
devDependency-only and absent from `web/dist`. Pinned `vitest` and
`@vitest/coverage-v8` to exactly **4.1.12** (patch within major 4) rather than 5.x,
to avoid unrelated breaking changes.

Verified: `npm audit` reports **0 vulnerabilities**; 42 files / **309 tests pass**;
production build clean.

Dependabot still prints "2 moderate" on push because it evaluates against its last
scan; it should close both on the next scan of the fixed lockfile.

## 2. `finalize` bound to the waiting device (`8258db7`)

`finalize` handed out the confirmed session cookie to anyone holding a `qr_id` -
and `qr_id` appears in the QR URL, the SSE URL, browser history and access logs, so
one leaked id was an account takeover inside the 2-minute window.

- `POST /api/auth/qr` now mints a CSPRNG secret (`generate_random_token`, fails
  closed), stores only its SHA-256 in `device_pair_sessions.secret_hash`, and
  returns it in a **path-scoped** `HttpOnly; SameSite=Lax; Max-Age=130` cookie
  (`Path=/api/auth/qr/<id>`), with `Secure` only when the request arrived over TLS.
  Path scoping keeps two concurrent sessions (StrictMode creates two in dev) from
  overwriting each other, and the secret never appears in the body or the log.
- `finalize` compares in **constant time** and fails closed with **403 and no
  cookie** when the secret is missing or wrong. A success clears the cookie with
  the same `Path`.

Verified: refusals are asserted, not just the happy path - no cookie -> 403, wrong
secret -> 403, another session's cookie -> 403 - plus the success path. Live:
create sets the scoped cookie with no secret in the body, `finalize` is 403 without
it and 400 (not yet confirmed) with it.

## 3. QR rate limits and SSE cap (`cec124d`)

- Per-client sliding windows (60 s), identity = **last** `X-Forwarded-For` entry
  (correct whether Caddy appends or replaces), else a shared `direct` bucket:
  create 10, lookup 20, confirm 20, finalize 30, wait 10, status 120 per minute.
- Refusals are **429 JSON with `Retry-After`** (`AppError::TooManyRequests`).
- SSE: **64 global** (`MEDIA_SERVER_QR_MAX_SSE`) and **4 per client**. The
  `OwnedSemaphorePermit` is moved into the response stream state, so a disconnect,
  timeout or unread body releases it; a permit leaked per abandoned stream would
  shrink the pool permanently.
- The identity table is capped at 8192 and refuses **new** identities when full
  rather than evicting live ones (eviction would reset an attacker's budget).

Verified: unit tests for the window, per-identity isolation, global cap, and
permit release on drop; an integration test proving the 11th create is 429 with
`Retry-After`, another client is unaffected, and a different route does not spend
the create budget. Live with a spoofed `X-Forwarded-For` (so the household bucket
was untouched): 10 creates pass, 11th is 429 (`retry-after: 59`), a second identity
succeeds, `status` and `wait` still answer, all rows cleaned up.

The SSE cap is proven by unit test; it was **deliberately not live-exhausted** (64
open streams would occupy the production pool briefly for no extra information).

## 4. Plaintext pair code dropped (`d184283`)

- `find_pair_session_by_code` matches `code_hash`; `confirm_pair_session` selects
  `code_hash` and compares the hash of the **case-normalized** submission (charset
  is uppercase, so lowercase typing still works), in constant time.
- `create_pair_session` still returns the code for the TV and the QR URL, but
  persists only the hash.
- `db.rs`: `code` removed from `CREATE TABLE`; `ALTER TABLE ... DROP COLUMN IF
  EXISTS code`; `idx_device_pair_code` dropped and replaced by
  `idx_device_pair_code_hash`. The old `CREATE INDEX ... (code)` **had to go in
  the same change** - it would fail schema init on every start once the column was
  gone.
- The flow test now looks up a **lowercase** code and confirms with **code only**.
  Previously it sent `code` and `sig`, and since either is accepted, a broken code
  comparison would have passed. A **sig-only** confirm was added so the scanned-QR
  path stays covered.

Verified: full Rust suite green; probe 22/22; live schema shows `code_hash` +
`secret_hash`, no `code`, and `idx_device_pair_code_hash`; live create succeeds
(the write path no longer touches the column); test rows removed.

## Deploy state

- `rust/target/release/media-server-api.exe` rebuilt **2026-10-23 00:38:45**, newer
  than every commit above; `MediaServerRust` service **Running**.
- Live schema applied by `ensure_schema` on that restart (no manual SQL).
- `python scripts/probe_android_api.py`: **22/22 per contract** after the restart.

## Rollback notes

- Item 4 is irreversible as shipped: a binary from before `d184283` inserts into
  `code`, so it fails against the dropped column. Re-add the column first if a
  rollback is ever needed. The data is ephemeral (2-minute rows), so nothing of
  value was lost.
- Items 2 and 3 need no schema rollback; the limiter is in-process and resets on
  restart.

## Remaining (not part of this batch)

- Posture items from the briefing: guest-mode default, plaintext secrets at rest,
  backups on the same volume as the data, Cloudflare API token rotation.
- Dependabot's stale "2 moderate" banner will clear on its next scan.
- Pre-existing and unchanged: three Flutter test files cannot run on this host
  (`libmpv-2.dll` missing) - AGENTS.md queue item 6.

## Reproducing the verification

```powershell
# Rust tests need the MSVC + Windows SDK environment on this host:
cmd /c C:\Users\anis7\AppData\Local\Temp\opencode\cargo-msvc.cmd test `
  --manifest-path rust\Cargo.toml -- --test-threads=1

python scripts/probe_android_api.py
```

The wrapper exists because `C:\msys64\usr\bin\link.exe` shadows MSVC's linker on
`PATH`, and `vcvars64.bat` on this install omits the UCRT `LIB`/`INCLUDE` paths.
