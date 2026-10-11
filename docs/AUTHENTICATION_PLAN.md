# Authentication & Access Control Plan

**Status:** Proposal — not implemented.
**Author:** Phase 2 React work, 2026-10-12
**Addresses:** `AGENTS.md` §4 ("the stable Cloudflare hostname is not authentication.
Add access control before wider public sharing"), roadmap §5 non-negotiable rule 2
(authentication is a compatibility requirement) and the roadmap's requirement for an
explicit **authz matrix**.

**Decision taken 2026-10-12:** the scheme is a **Google Sign-In (OIDC)** front door for
humans on browsers, backed by a first-class **API token system** for programmatic
clients, with **signed media URLs** for the devices that can do neither.

---

## 0. The risk that decides the whole design

The server is reachable from the internet at `media.anisparvez.in` with no
authentication. **Google Sign-In does not fix that on its own: anyone on earth with a
Google account can sign in.**

Adding a Google button without an account allowlist is *worse than no authentication*
in one specific respect — it creates a false impression that the server is private
while remaining just as open, and it produces a clean, plausible-looking audit trail
of who did what.

So an allowlist is **not an optional refinement of this design; it is a precondition.**
The first design I proposed did not need one (a single shared password), which is why
this is called out at the top rather than buried in "open decisions".

- Sign-in is permitted only for e-mail addresses on an explicit allowlist.
- New/unlisted accounts are rejected **after** a successful Google exchange — the
  server must not create a user row for an unknown identity.
- Bootstrap: the allowlist lives in the `settings` table (or the NSSM environment);
  it is not editable from the UI. An admin adding an address is a deliberate act.
- There is **no "first sign-in becomes admin" rule.** On a publicly reachable server
  that rule is a race an attacker wins by loading the page first.

## 1. Current state

Verified against the running service and the source, 2026-10-12:

| Question | Finding |
|---|---|
| Any auth on any route? | **None.** Zero auth calls in `app/routes/api.py`; no login route, no session, no token check. |
| `SECRET_KEY`? | **Absent** — not in `app/config.py` or `app/__init__.py`. Flask's signed-cookie sessions cannot work until one is introduced. |
| User / auth tables? | **None.** `app/db.py` creates only `movies`, `progress`, `devices`, `device_watch_history`, `ip_cache`, `settings`. |
| Public exposure | `media.anisparvez.in` via Cloudflare tunnel, serving the app with **no authentication at all**. |
| Listener | Waitress bound to `0.0.0.0:8000` — reachable by anything that can route to the LAN address. |

Anyone who knows the hostname can browse the library, read watch history, delete
media (`POST /api/media/delete`), change storage settings, trigger scans and
transcodes, and stream every file.

## 2. Threat model — three independent paths

Authentication is only as good as the *narrowest* path to the app. There are three,
and each must be considered:

| # | Path | Reaches | Can carry credentials? |
|---|---|---|---|
| 1 | **Public** — Cloudflare tunnel, `media.anisparvez.in` | From the internet | Browsers: yes. API clients: yes. Cast/DLNA receivers: **no**. |
| 2 | **Tailnet** — `media-server.tail7d5bf9.ts.net` | Tailscale members | Same as above. |
| 3 | **LAN** — `http://<lan_ip>:8000` | Anyone on the home LAN, and **every Cast/DLNA receiver** | **No.** |

**Path 3 is the constraint that shapes the media plane.** `build_media_url()`
(`app/services/cast_service.py:287-293`) builds media URLs on the *LAN address* and
hands them to Cast and DLNA devices, which fetch them themselves:

```python
base = validate_origin(origin or '') or f'http://{lan_ip()}:{server_port}'
return f'{base}/media/{urllib.parse.quote(rel)}'
```

A Samsung TV reading a DIDL-Lite `<res>` URL, or a Cast receiver running its own
loader, **cannot log in**. It cannot complete an OAuth redirect, hold a session
cookie it did not obtain, or attach an `Authorization` header. Any design that puts an
interactive login in front of `/media` and `/hls` breaks casting and DLNA — and
`AGENTS.md` §6 records how much hard-won behaviour depends on exactly those paths.

**Stated plainly:** the LAN path cannot be fully protected from an attacker already
on the home network. The goal is to make the *internet* path require a real
credential and to keep the LAN path working for devices that cannot authenticate,
while recording the residual risk rather than implying it away.

## 3. The three credential classes

### 3.1 Google Sign-In → server session cookie (humans, browsers)

- OIDC authorization-code flow with **PKCE** and a validated `state` parameter.
- Scopes: `openid email profile`. Nothing more — no Drive, no Gmail.
- The Google ID token is **verified, not trusted**: signature against Google's JWKS
  (`https://openidconnect.googleapis.com/v1certs`), plus `aud` == our client id,
  `iss`, `exp`, and nonce. Then discarded.
- **The session is ours, not Google's.** The ID token lives ~1 hour; a signed
  `HttpOnly; Secure; SameSite=Lax` cookie with our own idle + absolute TTL is issued
  instead. Storing the ID token as the session would log people out hourly and would
  put a third-party credential in a cookie.
- CSRF protection on every mutating request (double-submit or synchronizer token).
  `SameSite=Lax` alone is not sufficient.
- Revocation via `https://oauth2.googleapis.com/revoke` plus our own session deny-list.

**Secret handling.** The client id/secret go into the **NSSM `AppEnvironmentExtra`**,
never the repo and never a committed `.env`. `docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md`
§4 records an existing NSSM environment trap; that failure mode applies here too, and
a silently-missing secret must fail loudly at startup rather than at first login.

**Redirect URIs must be registered exactly** in the Google Cloud console — one per
reachable origin, e.g. `https://media.anisparvez.in/auth/google/callback`,
`http://media-server.tail7d5bf9.ts.net:8000/auth/google/callback`, and a localhost
URI for development. Google rejects mismatches, and a missed tailnet URI would break
sign-in specifically on the path that is supposed to be the fast one.

### 3.2 API token system (programmatic clients)

A first-class, managed token system — not a shared password.

- Long-lived, per-device, human-labelled ("Living room TV", "Pixel 8").
- **Generated with ≥256 bits of entropy, shown exactly once, stored only as a hash**
  (SHA-256 is sufficient here — the token is high-entropy random, not a user-chosen
  password, so no slow KDF is warranted; passwords would need one).
- Carried as `Authorization: Bearer <token>`.
- Revocable individually, with `created_at`, `last_used_at`, `expires_at`, `revoked_at`.
- Token **creation requires a session** — so a token can only be minted by someone who
  has already passed Google sign-in *and* the allowlist.

This is where the two halves of the design meet: **sign in with Google on the web, then
mint a token for the TV.** That solves the awkward part of Fire TV enrolment, which in
the first draft was listed as an open problem (typed token entry is poor UX on a
10-foot interface). It is now a QR code or a one-time pairing link rendered by the
already-authenticated web UI. `docs/PHASE_2_REACT_STATUS.md` notes the React app has
no token UI yet; that is Phase D work.

**`X-Device-Id` is an identifier, not a credential.** The Flutter client already
attaches a persistent one (`flutter_client/lib/core/api/api_interceptors.dart:36`).
It must never be treated as authenticating anything — it is attacker-controlled and
must remain so in the code, i.e. it may scope *data* (watch history) but never grant
*access*.

### 3.3 Signed media URLs (Cast, DLNA — the devices that can do neither)

- `GET /media/<path>?exp=<unix>&sig=<hmac-sha256(secret, path|exp|scope)>`
- Scope is narrow: `media` for `/media` and `/hls`; nothing else.
- Short TTL (30–60 min), refreshed on each cast.
- The only mechanism Cast/DLNA can satisfy, and safe to issue to a device that cannot
  authenticate, because the URL itself is the credential and it expires.
- The signature covers the **exact path**, so a token for one title cannot be edited
  into another.

## 4. Schema additions

```sql
CREATE TABLE users (
  id            INTEGER PRIMARY KEY,
  google_sub    TEXT NOT NULL UNIQUE,   -- Google's stable subject id
  email         TEXT NOT NULL,
  name          TEXT,
  picture_url   TEXT,
  role          TEXT NOT NULL DEFAULT 'viewer',   -- 'viewer' | 'admin'
  created_at    TEXT NOT NULL,
  last_login_at TEXT
);

CREATE TABLE auth_tokens (
  id            INTEGER PRIMARY KEY,
  user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  label         TEXT NOT NULL,
  token_hash    TEXT NOT NULL UNIQUE,   -- never store the token itself
  created_at    TEXT NOT NULL,
  last_used_at  TEXT,
  expires_at    TEXT,
  revoked_at    TEXT
);
```

Plus a `denylist`/`revoked_sessions` table if session revocation must be immediate
rather than bounded by the session TTL.

**Both tables are new.** There is currently no user concept at all, and this is the
first schema change of its kind since the PostgreSQL migration work — see §7.

## 5. Authz matrix

The roadmap asks for this explicitly. Roles are deliberately minimal: a
single-household server does not need per-user sharing profiles.

| Surface | Route(s) | Anonymous | Allowed Google user | Token holder |
|---|---|---|---|---|
| Google sign-in | `GET /auth/google`, `GET /auth/google/callback` | ✅ (the door) | — | — |
| Library read | `GET /api/movies`, `/api/movie/<f>`, `/api/media-info/<f>` | ❌ | ✅ | ✅ |
| Watch progress | `GET`/`POST /api/progress` | ❌ | ✅ | ✅ |
| **Media plane** | `/media/*`, `/hls/*` | ❌ | ✅ | ✅ |
| **Cast/DLNA media** | `/media/*`, `/hls/*` with a valid `sig` | ✅ *(signed URL only)* | ✅ | ✅ |
| Seek previews | `/api/seek-preview-meta/*`, `/seek-preview/*` | ❌ | ✅ | ✅ |
| **Devices** | `/api/devices*` | ❌ | admin | ✅ |
| **Cast control** | `/api/cast/*` | ❌ | admin | ❌ |
| **Destructive** | `POST /api/media/delete`, `/api/storage/*`, `/api/scan`, `/api/upload*` | ❌ | **admin** | ❌ |
| **Token minting** | `POST /api/auth/tokens` | ❌ | admin | ❌ |
| Subtitles | `/subtitles/*` | ❌ | ✅ | ✅ |
| System status | `/api/system-status`, `/api/transcodes` | ❌ | ✅ | ✅ |

Three decisions worth stating explicitly:

- **`/api/media/delete` is admin-only, always.** It deletes files, and it currently
  returns HTTP 200 `'success': True` **even when the purge recorded refusals**
  (`media_service.py:455` vs `:463`; risk item 6 in `MIGRATION_STATUS.md`). Fix that
  in the same change: once delete is the most security-relevant operation on the
  server, "success" must mean success.
- **A signed media URL confers playback only.** It must never authorise cast, scan or
  delete — those need a real credential.
- **Tokens are viewer-scoped by default.** A token should not be able to mint more
  tokens, delete media, or see the device fleet. Otherwise one leaked TV token is
  equivalent to admin.

## 6. Phased rollout

Every phase is independently reviewable and revertible. Nothing is enforced until the
phase that enforces it has been verified against the real device.

| Phase | Work | Gate before proceeding |
|---|---|---|
| **A — Foundation (no enforcement)** | `SECRET_KEY` + NSSM env; `users`/`auth_tokens` tables; allowlist; `require_auth(role)` decorator; **every** protected route wrapped but gated behind `MEDIA_SERVER_AUTH=off` (default `off`). | 720-test suite green with enforcement off; decorator proven by new tests |

### Phase A — delivered 2026-10-12

Branch `feat/react-web-frontend`. Enforcement is **off**, so the running service is
unchanged.

| Piece | Where |
|---|---|
| `auth_enabled()`, `secret_key()`, `auth_allowlist()` | `app/config.py` |
| `require_auth()`, `check_control_plane_request()`, `resolve_identity()`, `role_satisfies()`, `warn_if_media_plane_anonymous()`, `startup_auth_diagnostics()` | `app/services/auth_service.py` |
| Gate registration | `app/__init__.py` (`before_request`) |
| `users` + `auth_tokens` (SQLite) | `app/db.py` `init_db()` |
| `users` + `auth_tokens` (PostgreSQL) | `app/db.py` `POSTGRES_MIGRATIONS` version **2** |
| 52 tests | `tests/test_auth_foundation.py` |

**Deliberate properties**

- **Inert by default.** With `MEDIA_SERVER_AUTH` unset, every protected route
  behaves exactly as before. `config.auth_enabled()` reads the environment at
  *call* time (like `is_amf_enabled`), so the same client exercises both states.
- **Fail closed.** With enforcement on and no credential provider (the Phase A
  state), every protected route answers **401** with a message naming the
  recovery step (`MEDIA_SERVER_AUTH=0`). A half-enabled auth system that left the
  destructive routes reachable would be worse than none, because it would look
  protected.
- **The media plane is not gated.** Cast and DLNA receivers fetch `/media` and
  `/hls` themselves and cannot authenticate. `warn_if_media_plane_anonymous()`
  logs that gap at startup rather than leaving it to be discovered. Phase E
  closes it with signed URLs.
- **Scoping is by blueprint name, not URL prefix.** A new route on `api`,
  `pages`, `subtitles` or `cast` is protected by default, without anyone
  remembering to decorate it. `cast` additionally requires `admin`.

**Verification**

- **772 passed / 28 skipped** (720 baseline + 52 new).
- Library files (100), production `movies` rows (44) and the `cache/hls` tree
  (42 757 entries) were **hash-identical before and after** the full run.
- The schema change was rehearsed against a *copy* of the production database:
  8 → 10 tables, exactly `auth_tokens` and `users` created, nothing removed, every
  pre-existing table byte-identical. The live service picks the tables up on its
  next restart; it has not been restarted.

**Not done in Phase A, by design**

- No credential provider (`resolve_identity()` always returns `None`).
- Per-route `admin` mapping for the destructive endpoints (delete / storage /
  scan / upload / devices). Safe to defer *because* the fail-closed path makes
  those routes unreachable rather than over-permissive until a provider exists.
  Phase B.
- The service has **not** been restarted and `MEDIA_SERVER_SECRET_KEY` has **not**
  been set. Neither is needed while enforcement is off.
| **B — Google Sign-In** | OIDC flow, JWKS verification, session issuance, allowlist enforcement, CSRF, logout. React login page. | Sign-in works against the live server; **an unlisted Google account is rejected** (must be tested explicitly) |
| **C — API token system** | Mint/list/revoke; `Authorization: Bearer` resolution; hashed-at-rest storage; token shown once. | Tokens issue, verify, and revoke correctly; suite green |
| **D — Clients** | Flutter/Fire TV token enrolment; web UI to mint tokens + QR/pairing link. Flutter suite via `scripts\run_flutter_tests.ps1`. | Flutter suite green; TV client connects and resumes |
| **E — Media plane** | Signed URLs from `build_media_url`; media-plane resolution accepting session **or** bearer **or** signature. | **Cast and DLNA verified on the real TV** — not mocked |
| **F — Enforcement** | Default `MEDIA_SERVER_AUTH=on`; anonymous media access removed; secret rotation documented. | Full suite + Flutter suite + live Cast/DLNA all green |

**Rollback:** every phase sits behind `MEDIA_SERVER_AUTH`. Setting it to `off` restores
today's behaviour with no code revert — the same escape-hatch pattern already used by
`MEDIA_SERVER_PURGE_ON_STARTUP` and `MEDIA_SERVER_TEST_POSTGRES_URL`.

## 7. Testing requirements

Per `AGENTS.md` §7 and the roadmap's testing gates:

- **Contract tests** — `tests/test_api_contracts.py` must gain auth cases and be
  updated for the new 401/403 responses. Note it currently has **15 test definitions
  against 65 operations** (`docs/PHASE_2_REACT_STATUS.md`); the unauthenticated
  surface it pins is about to change deliberately.
- **Unit** — decorator logic, token hashing/verification, CSRF, signature generation
  and its rejection cases (expired, tampered path, wrong scope), and the allowlist
  rejection path.
- **Google exchange must be mocked in CI** — JWKS, token endpoint and identity are all
  faked. Live Google verification sits behind the existing `liveServerSkip` pattern
  (`MEDIA_SERVER_LIVE_TESTS=1`), which must not be flipped on in normal runs.
- **Regression (mandatory)** — the existing **720-test suite must stay green** with
  auth off, and the isolation guarantees in `AGENTS.md` §7 (library file list, `movies`
  rows, `cache/hls` listing unchanged before/after) must hold with auth on.
- **Flutter suite** — via `scripts\run_flutter_tests.ps1`, never bare `flutter test`.
- **Hardware / real-device (cannot be mocked)** — Cast and DLNA against the Samsung
  DU7000. `AGENTS.md` §6 records these behaving in ways mocks do not predict; a green
  suite is not evidence here.
- **Service worker** — `library.html` registers `/sw.js`. If a service worker ever
  caches `/api/*` responses, authenticated data becomes readable from a shared cache.
  Verify the media/API plane is excluded from any Cache Storage policy.

## 8. Interaction with the PostgreSQL migration

`users` and `auth_tokens` would be the **first new tables since the PostgreSQL adapter
landed**, and `MIGRATION_STATUS.md` records that the Phase 3 exit gate is still unmet —
no demonstrated data transfer or recovery, and no backup/restore drill exists.

Two consequences:

1. Adding tables to SQLite now means they must also be carried across in the eventual
   transfer. Cheap now, expensive if deferred until after cutover.
2. **Authentication must not depend on PostgreSQL.** It must work against the current
   SQLite store, or the server becomes un-authenticatable in exactly the incident where
   the database is the thing that broke.

## 9. Explicit non-goals and open decisions

- **No per-user accounts or sharing profiles.** Two roles are enough for a
  single-household server. Multi-user adds surface with no user.
- **Open decision — admin bootstrap. DECIDED 2026-10-12: the allowlist lives in the
  `settings` table**, under a dedicated key, edited from an admin-only route — not
  in an NSSM environment variable. Consequences:
  - Permitted addresses can be added **without a service restart**, which is the
    main practical win.
  - `MEDIA_SERVER_AUTH_ALLOWLIST` **remains supported as a break-glass
    administrator**, and the effective allowlist is the **union** of the two. The
    table can be edited by anyone who can reach the web UI; the environment
    variable can only be set by someone with machine access. Keeping both, unioned,
    means emptying the table by accident cannot lock the operator out.
  - **Verified safe against self-enrolment:** `/api/storage/settings`
    (`api.py:757-782`) is key-restricted — it only ever calls
    `set_setting('retention_policy', …)` — so no existing route can write an
    arbitrary `settings` key. The allowlist must stay behind a dedicated
    admin-only route; a generic "set any key" endpoint would defeat the whole
    allowlist.
  - **Bootstrap:** the allowlist must be non-empty before Phase B is enabled. The
    documented first-run path is to set `MEDIA_SERVER_AUTH_ALLOWLIST` in the NSSM
    environment, sign in through that break-glass identity, then manage the table
    from the UI. There is deliberately still no "first sign-in becomes admin"
    rule (§0).
- **Open decision — token expiry.** A TV token with no expiry is convenient; a token
  with a short expiry needs a re-pairing flow on a device that may be switched off for
  weeks. Suggest long-lived (90 days) with visible expiry in the UI.
- **Open decision — LAN binding.** Waitress listens on `0.0.0.0:8000`. Once auth is
  enforced this is mostly acceptable, but it should be a deliberate choice, not a
  default. Binding loopback + Tailscale only — with the LAN address still served for
  Cast/DLNA via signed URLs — is the strongest option if the signed-URL model proves
  sufficient.
- **Open decision — account de-authorisation.** When someone is removed from the
  allowlist, their already-issued tokens keep working until expiry unless explicitly
  revoked. Decide whether removal cascades to token revocation.

## 10. Cloudflare Access (defence in depth, optional)

**Cloudflare Access** in front of `media.anisparvez.in` would add browser protection
with almost no application code. It is **not sufficient on its own**:

- It cannot authenticate a Cast receiver or DLNA renderer — they would be blocked or
  forced through a flow they cannot complete.
- It does not cover path 3 (LAN) at all.
- Flutter would need an OAuth device flow to obtain a token.

Its role is defence in depth on the **browser** surface, layered under application
auth, with API/media paths explicitly passed through. Worth doing; not worth doing
*instead* — and redundant with Google Sign-In for the same surface.

---

## Summary

The two decisive constraints are:

1. **The server is publicly reachable, so Google Sign-In without an allowlist is not
   security** — it is a login form in front of an open door. The allowlist is a
   precondition, not a refinement.
2. **Cast and DLNA receivers cannot authenticate** (`app/services/cast_service.py:287-293`
   hands them LAN URLs they fetch themselves), so the media plane needs signed URLs
   even while the control plane moves behind sessions and tokens.

Start at **Phase A**, which adds all the machinery but enforces nothing, so the
existing 720-test suite stays green and the change is provably inert before any
behaviour changes. Phase B should not be enabled until the allowlist exists.