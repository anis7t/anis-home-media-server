# 2026-10-23 03-18 IST — Google sign-in 403: allowlist cleared + hardening

Agent: opencode (DeepSeek V4.1 Flash)
Scope: User-facing sign-in outage (`anis7t@gmail.com` → 403 "This account is not
permitted to use this server") plus the durable hardening the outage demanded.

Commits: code on branch `feat/rust-react-postgres-migration` — allowlist policy,
allowlist endpoint authorization, tests; docs updates; web copy fix.

## Objective

1. Restore Google sign-in for `anis7t@gmail.com` (admin).
2. Keep open sign-in for any other Google account, so "other users should also be
   able to sign in".
3. Make the fix durable and secure.

## Diagnosis

The address was never the problem; the **allowlist was**.

- Live `settings.auth_allowlist` held `operator@example.com,second@example.com`
  (the `auth_flow_test.rs` fixture strings). A **non-empty** allowlist is exclusive,
  so every real account was refused; the live log showed
  `AUTH: Rejected unlisted identity: anis7t@gmail.com`.
- The row had to be cleared (done): sign-in is open again (`effective: []`).
- The stale row's author could not be proven (allowlist POSTs were not audited at the
  time), but the endpoint had an exposure: `GET`/`POST /api/auth/allowlist` were gated on
  `MEDIA_SERVER_AUTH`, which is unset in this deployment, so **they were unauthenticated
  and writable**. A live anonymous POST during diagnosis wrote `probe@example.test`; removed
  immediately.
- The code also inverted the policy: an empty list + `MEDIA_SERVER_AUTH=1` returned
  `!auth_enabled` = false (deny everyone). The documented Phase 1 intent ("cleared so
  anyone can sign in") was therefore not what the code did once enforcement was ever on.

## What changed (approved plan → delivery)

1. **Policy** — new pure `AuthService::allowlist_allows(effective, email)`: empty → open
   (any verified Google account may sign in; viewer unless in `MEDIA_SERVER_ADMIN_EMAILS`);
   non-empty → exclusive, case/whitespace-insensitive. `is_email_allowed` delegates.
2. **Security** — `GET`/`POST /api/auth/allowlist` now admin-only **always** (Admin PIN or
   admin session); 401 otherwise; mutations only for admins; invalid body still 400.
3. **Tests** — pure policy tests (empty→open, non-empty→restrict) and route tests (anonymous
   GET/POST → 401, no mutation, Admin PIN → 200, invalid body → 400, zero allowlist residue).
4. **Docs** — new *Sign-in allowlist invariants* section in `AGENTS.md`; status entry in
   `docs/PROJECT_STATUS.md`; supersession note in `docs/AUTHENTICATION_PLAN.md`.
5. **Web** — `LoginScreen` copy no longer mentions an allowlist ("Sign in with your Google
   account to continue").

## Verification

- Targeted allowlist tests: pass (3 lib unit + 1 route).
- Full Rust suite: **345 passed / 0 failed / 33 suites**.
- Web: **42 files / 314 tests passed**; `npm run build` green.
- Release build + restart via `scripts/restart_rust_service.ps1`: service Running, health 200,
  `/api/movies` 200; binary `LastWriteTime` 2026-10-23 03:22:20 > source commit 03:04:28.
- Live post-deploy: anonymous `GET /api/auth/allowlist` → **401** (was 200); admin PIN
  `791654` → **200** with `effective: []`; admin + invalid body → **400**.
- Live DB: `settings.auth_allowlist` count = **0** in `media_server`; 0 residue in
  `media_server_test`.
- `python scripts/probe_android_api.py` → **all 22 Android client endpoints OK per contract**.

## Outstanding / owner actions

- Retry Google sign-in in the browser (`anis7t@gmail.com`) — expected success now that the
  allowlist row is gone; confirm you land in the app and stay admin.
- Consider rotating `admin_pin` to something you chose (`791654` is the live value).
- Consider scoping the Cloudflare token (known outstanding item).
- The Fire TV video-intro device check remains outstanding from Phase 11 Slice 11.8.

## Risks / notes

- Open sign-in means any Google account can sign in as **viewer**; only
  `MEDIA_SERVER_ADMIN_EMAILS=anis7t@gmail.com` becomes admin.
- The allowlist is now the brake (admin-only), not the sign-in gate's enforcement switch.
- No `/api/*` contract shape changed; Flutter probe 22/22 green.

## Next

- Commit the change set.
- Session handoff written to this file; update `docs/PROJECT_STATUS.md` (done) and any
  relevant memory notes.
