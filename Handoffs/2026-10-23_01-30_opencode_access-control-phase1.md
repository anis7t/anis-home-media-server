# 2026-10-23 01:30 IST - Access control Phase 1: admin bootstrap + upload gating

Agent: opencode (DeepSeek V4.1 Flash)
Scope: backend auth + one test file + config + docs. No frontend changes.

## Objective

"Anyone on earth with a Google account can sign in" was the open posture. Phase 1 closes the
account-creation side without breaking guest browsing, casting, or device tokens: a configured list
of admin emails is promoted to `admin` on Google sign-in; everyone else is a `viewer`; upload stays
admin-only (PIN or signed-in admin). The media library itself stays public.

## What changed

- `rust/src/config.rs`: `pub fn admin_emails()` reads `MEDIA_SERVER_ADMIN_EMAILS` (comma list,
  lowercased/trimmed/deduped).
- `rust/src/services/auth_service.rs`:
  - `oauth_callback` now sets `role` from `AuthService::role_for_email(&email)` and writes it on
    both insert and conflict update (idempotent; removal from the list demotes on next sign-in).
  - `resolve_session_or_token` session-cookie path now reads `COALESCE(u.role, s.role)` instead of
    the frozen `s.role`, so a role change in the `users` table is reflected on the next request
    without re-signing-in. Bearer-token path already read `u.role`.
  - Added `pub fn role_for_email`.
- `rust/tests/admin_bootstrap_test.rs` (new, 4 tests): role_for_email parsing, per-request role
  re-check, upload init gating (anonymous/viewer -> 403, admin -> past the gate), empty default.
- Config: `MEDIA_SERVER_ADMIN_EMAILS=anis7t@gmail.com` in `.env` and NSSM `AppEnvironmentExtra`.
  `MEDIA_SERVER_AUTH_ALLOWLIST` cleared so anyone can still sign in.
- Docs: `AGENTS.md` secondary item 6 updated; handoff + vault.

## Evidence

- `cargo test --test admin_bootstrap_test`: 4 passed.
- `cargo test` (auth_flow, auth_pin_login, admin_bootstrap, upload_flow, --test-threads=1): 4+7+3+5 = 19 passed, 0 failed.
- Release build succeeded; service restarted; binary timestamp 01:25:56 after commit; health 200.
- Upload gating verified by test: anonymous 403, viewer session 403, admin session not 403.

## Risks / notes

- If `MEDIA_SERVER_ADMIN_EMAILS` is unset, no Google account is admin (only PIN). Safe default.
- Role demotion takes effect on the next request for the admin flag (via users table), but the
  session row's role is only refreshed on next sign-in. Documented.
- PIN-created admin (`admin@local`, google_sub `admin_pin`) is never touched by OAuth, so it
  stays admin regardless of the env var.
- Phase 2/3 (device user_id, admin oversight UI) and Phase 4 (approval flow, domain restriction)
  are NOT done.

## Rollback

Revert the commit; remove `MEDIA_SERVER_ADMIN_EMAILS` from `.env`/NSSM env; rebuild+restart. No
schema change was made, so no migration rollback is needed.
