# Authentication & Access Control Plan

**Status:** Proposal — not implemented.
**Author:** Phase 2 React work, 2026-10-12
**Addresses:** `AGENTS.md` §4 ("the stable Cloudflare hostname is not authentication.
Add access control before wider public sharing"), roadmap §5 non-negotiable rule 2
(authentication is a compatibility requirement) and the roadmap's requirement for an
explicit **authz matrix**.

---

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
and they must each be considered:

| # | Path | Reaches | Can carry credentials? |
|---|---|---|---|
| 1 | **Public** — Cloudflare tunnel, `media.anisparvez.in` | From the internet | Browsers: yes. API clients: yes. Cast/DLNA receivers: **no**. |
| 2 | **Tailnet** — `media-server.tail7d5bf9.ts.net` | Tailscale members | Same as above. |
| 3 | **LAN** — `http://<lan_ip>:8000` | Anyone on the home LAN/ Wi-Fi, and **every Cast/DLNA receiver** | **No.** |

**Path 3 is the one that constrains the design.** `build_media_url()`
(`app/services/cast_service.py:287-293`) constructs media URLs on the *LAN address*
and hands them to Cast and DLNA devices, which fetch them themselves:

```python
base = validate_origin(origin or '') or f'http://{lan_ip()}:{server_port}'
return f'{base}/media/{urllib.parse.quote(rel)}'
```

A Samsung TV reading a DIDL-Lite `<res>` URL, or a Cast receiver running its own
loader, **cannot log in**. It cannot answer a challenge, hold a cookie, or attach
an `Authorization` header. Any design that requires interactive authentication on
`/media` and `/hls` will break casting and DLNA playback — both of which have
cost significant effort and carry hard-won invariants in `AGENTS.md` §6.

**Stated plainly:** the LAN path cannot be fully protected against an attacker
already on the home network. The goal is to make the *internet* path safe and to
keep the LAN path working for devices that cannot authenticate, while recording
that residual risk explicitly rather than implying it away.

## 3. Design — three credential classes, one media plane

The rule that resolves the tension: **the media plane accepts any credential
class, including a signed URL.** Control-plane routes require a real credential.

### 3.1 Session cookie — for the React web frontend
- Signed, `HttpOnly`, `Secure` (when public), `SameSite=Lax`, short idle + absolute TTL.
- Requires introducing `SECRET_KEY` (generated once, stored outside the repo, injected
  into the NSSM service environment).
- CSRF: double-submit token or synchronizer pattern for all mutating requests.
  `SameSite=Lax` alone does not cover same-origin XSS-read forms of the problem.

### 3.2 Bearer token — for Flutter/Fire TV and XHR
- Long-lived, per-device, **hashed at rest** (store only a hash, like a password),
  revocable, with a visible label (" living room TV").
- Carried as `Authorization: Bearer <token>`.
- Aligns with the existing device model: the Flutter client already attaches a
  cryptographically persistent `X-Device-Id` on every request
  (`flutter_client/lib/core/api/api_interceptors.dart`), so a token can be issued
  once per device and rotated independently of that id.

### 3.3 Signed media URL — for Cast, DLNA and any client that cannot send headers
- `GET /media/<path>?exp=<unix>&sig=<hmac-sha256(secret, path|exp|scope)>`
- Scope is narrow: `media` for `/media` and `/hls`; nothing else.
- Short TTL (suggest 30–60 min), refreshed on each cast.
- This is the only mechanism Cast/DLNA can satisfy, and it is safe to issue to a
  device that cannot authenticate, because the URL itself is the credential and
  it expires.
- **Unguessable and non-enumerable:** the signature covers the exact path, so a
  token for one title cannot be edited into another.

## 4. Authz matrix

The roadmap asks for this explicitly. Roles are deliberately minimal.

| Surface | Route(s) | Anonymous | Viewer | Admin |
|---|---|---|---|---|
| Login | `POST /api/auth/login` | ✅ | — | — |
| Library read | `GET /api/movies`, `/api/movie/<f>`, `/api/media-info/<f>` | ❌ | ✅ | ✅ |
| Watch progress | `GET`/`POST /api/progress` | ❌ | ✅ | ✅ |
| **Media plane** | `/media/*`, `/hls/*` | ❌ | ✅ | ✅ |
| Seek previews | `/api/seek-preview-meta/*`, `/seek-preview/*` | ❌ | ✅ | ✅ |
| **Cast/DLNA media** | `/media/*`, `/hls/*` with valid `sig` | ✅ *(signed URL only)* | ✅ | ✅ |
| Devices | `/api/devices*` | ❌ | ❌ | ✅ |
| **Destructive** | `POST /api/media/delete`, `/api/storage/*`, `/api/scan`, `/api/upload*` | ❌ | ❌ | ✅ |
| Subtitles | `/subtitles/*` | ❌ | ✅ | ✅ |
| System status | `/api/system-status`, `/api/transcodes` | ❌ | ✅ | ✅ |

Two decisions worth stating explicitly:

- **`/api/media/delete` is Admin-only, always.** It deletes files, and it currently
  returns HTTP 200 with `'success': True` **even when the purge recorded refusals**
  (`media_service.py:455` vs `:463`; risk item 6 in `MIGRATION_STATUS.md`). That
  defect is worth fixing in the same change: once a delete is the most
  security-relevant operation on the server, "success" must mean success.
- **Cast/DLNA receive media, never control.** `/api/cast/*` stays Admin-only; a
  signed media URL must not confer the ability to cast, scan or delete.

## 5. Phased rollout

Every phase is independently reviewable and independently revertible. Nothing is
enforced until the phase that enforces it has been verified on the real device.

| Phase | Work | Gate before proceeding |
|---|---|---|
| **A — Foundation (no enforcement)** | `SECRET_KEY` config + NSSM env; `auth_tokens` table; `require_auth(role)` decorator; **every** protected route wrapped but gated behind `MEDIA_SERVER_AUTH=off` (default `off`). Full 720-test suite still green. | Suite green with enforcement off; decorator proven by new tests |
| **B — Control plane** | Enable auth on `/api/*` + pages. Login endpoint, session issuance, CSRF. React login page. | React login works against the live server; Flutter still connects via existing path |
| **C — Clients** | Flutter token issuance + storage; `/login`-style token entry for Fire TV; token revocation UI. | Flutter suite green; TV client connects; cast still works |
| **D — Media plane** | Signed URLs from `build_media_url`; media-plane credential resolution accepting session **or** bearer **or** signature. | **Cast and DLNA verified on the real TV** — not mocked |
| **E — Enforcement** | Default `MEDIA_SERVER_AUTH=on`; anonymous media access removed. | Full suite + Flutter suite + live Cast/DLNA all green |

**Rollback:** every phase is behind `MEDIA_SERVER_AUTH`. Setting it back to `off`
restores today's behaviour without a code revert — the same escape-hatch pattern
already used by `MEDIA_SERVER_PURGE_ON_STARTUP` and
`MEDIA_SERVER_TEST_POSTGRES_URL`.

## 6. Testing requirements

Per `AGENTS.md` §7 and the roadmap's testing gates:

- **Contract tests** — `tests/test_api_contracts.py` must gain auth cases, and
  **must be updated for the 401/403 responses**. Note it currently has 15 test
  definitions against 65 operations (see `PHASE_2_REACT_STATUS.md`); the
  unauthenticated surface it pins is about to change deliberately.
- **Unit** — decorator logic, token hashing/verification, CSRF, signature
  generation and its rejection cases (expired, tampered path, wrong scope).
- **Regression (mandatory)** — the **existing 720-test suite must stay green** with
  auth off, and the isolation guarantees in `AGENTS.md` §7 (library file list,
  `movies` rows, `cache/hls` listing unchanged before/after) must hold with auth on.
- **Flutter suite** — via `scripts\run_flutter_tests.ps1`, never bare `flutter test`.
- **Hardware / real-device (cannot be mocked)** — Cast and DLNA against the
  Samsung DU7000. `AGENTS.md` §6 records that these behave in ways mocks do not
  predict; a green suite is not evidence here.

## 7. Edge hardening (defence in depth, optional)

**Cloudflare Access** in front of `media.anisparvez.in` would give browser
protection almost immediately with no application code. It is **not sufficient on
its own**:

- It cannot authenticate a Cast receiver or a DLNA renderer — they would be
  blocked or forced through a browser flow they cannot complete.
- It does not cover path 3 (LAN) at all.
- Flutter would need an OAuth device flow to obtain a token.

Its appropriate role is defence in depth on the **browser** surface, layered on top
of application auth, with the API/media paths explicitly passed through. Worth
doing; not worth doing *instead*.

## 8. Explicit non-goals and open decisions

- **No per-user accounts or sharing profiles.** This is a single-household server;
  two roles (viewer/admin) are enough. Multi-user adds surface with no user.
- **No OAuth/SSO.** Adds an external dependency and a failure mode for a
  single-user service. Revisit only if sharing outside the household is real.
- **Open decision — LAN binding.** Waitress listens on `0.0.0.0:8000`. Once auth
  is enforced this is mostly fine, but it should be a deliberate choice, not a
  default: consider binding loopback + Tailscale only, and letting Cast/DLNA reach
  the LAN address explicitly, if the signed-URL model proves sufficient.
- **Open decision — token storage for Fire TV.** Typed entry is workable but poor.
  Options: QR code containing a one-time enrolment link, or a device-pairing flow
  initiated from the web UI.
- **Open decision — what to do about the existing `X-Device-Id` model.** Device ids
  are *identifiers*, not credentials, and must not be treated as either. The token
  must be the thing that authenticates.

---

## Summary

The single most important constraint is that **Cast and DLNA receivers cannot
authenticate** (`app/services/cast_service.py:287-293` hands them LAN URLs they
fetch themselves). Any design that gates `/media` and `/hls` behind an interactive
login will break them. The signed-URL approach keeps them working while making the
internet path require a real credential.

Work should start at **Phase A**, which adds all the machinery but enforces
nothing, so the existing 720-test suite stays green and the change is provably
inert before any behaviour changes.