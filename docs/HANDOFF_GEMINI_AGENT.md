# Handoff — Anthropic/Antigravity Gemini Agent
## Media Server: React migration, auth rework, details page

**Prepared:** 2026-10-13 · **Branch:** `feat/react-web-frontend`
**Commits:** `96ecc56` auth · `1b16f56` web · `dbec07a` invariant+guardrail · `b2af86c` handoff · `9f5aa97` docs

Read this before changing anything. Four sections matter most: **§3.1 a regression this
work introduced**, **§4 the one open decision**, **§5 the traps**, **§7 how to verify**.

---

## 1. What this project is

`anis7t/media-server` — a self-hosted film library. Flask backend serving a React
SPA, a Python transcoding pipeline, and a Flutter client for Android/Fire TV.
Single Windows host (dual AMD GPUs, NSSM services, Cloudflare tunnel).

**`AGENTS.md` is authoritative and non-negotiable.** It carries invariants that are
easy to break and expensive to rediscover — cache-purge blast radius, test isolation
landmines, player CSS contracts, transcoder frame accounting. Read it before editing.
Then `docs/PROJECT_STATUS.md` for current state.

### Commands

```powershell
# Python
.\venv\Scripts\python.exe -m py_compile app/config.py app/services/transcode_service.py
.\venv\Scripts\python.exe -m pytest tests/

# Frontend (cd web)
npm run typecheck      # tsc -b
npm run lint           # oxlint
npx.cmd vitest run     # 78 tests
npm run build          # MUST run; web/dist is what Flask serves

# Android/Fire TV (cd flutter_client)
.\scripts\run_flutter_tests.ps1    # NEVER a bare `flutter test` — see §5
```

`web/dist` is the served artefact. **Any change under `web/src` is invisible until
`npm run build` runs.** Two commits in this handoff would have shipped nothing without it.

---

## 2. Architecture in one paragraph

Cloudflare tunnel → `media.anisparvez.in` → Waitress (NSSM service `MediaServer`) →
Flask. The React SPA is served from `web/dist` by a catch-all in `app/__init__.py`
for any route no blueprint owns; `/api/*`, `/auth/*`, `/media/*`, `/hls/*` and every
blueprint route keep their explicit rules. One origin, so Google Sign-In's session
cookie works. Storage is tiered: `E:` holds app + DB + caches, `D:` holds cold media.

---

## 3. What was just delivered

### 3.1 Auth — three defects in "who is this caller?"

**Profile never resolved.** `resolve_identity()` used the **email** as the identity
subject, so `/api/auth/me` queried `users WHERE google_sub = <email>`. But
`google_sub` is Google's stable subject id (`1135675135…`), never an email. The lookup
could never match, so `name`/`picture_url` were permanently `NULL` even for a
signed-in user. The session now carries `sub`; resolution prefers it, falls back to email.

**Silent profile erasure.** `upsert_user()` overwrote `name`/`picture_url` on every
sign-in, so a token lacking those claims wiped a good profile. Now `COALESCE`.

**Device cookie lost on SPA pages.** The catch-all meant `pages_bp`'s `after_request`
no longer ran for `/`, so SPA responses silently stopped carrying `ms_device_id` —
which `device_service.current_device_id()` reads. Stamping moved to app level.

### 3.1a ⚠️ A regression THIS work introduced, and the lesson

Adding `sub` to the session **broke QR pairing**, and it was caught only at commit time.

`issue_session()` became the single place that mints a session for every credential
class and read `user["sub"]`. But the pairing route is built from a *device token*
record — `user_id` / `email` / `role`, never Google's claims — so it raised `KeyError`
and **pairing returned 500**. A working feature, broken by its own fix.

**Why it nearly shipped:** `test_auth_tokens.py` had never been run in isolation during
this work. "The auth suite is green" had been true — over a *different file set*.
**A green subset is not evidence about a file you did not run.**

Fixed in two parts, and they are not redundant:

- The pairing route resolves the full identity row via the new
  `google_auth.get_user_by_id()` — what a caller authenticating a *local* record rather
  than a Google callback needs. If the token outlived its user row it refuses `401`
  rather than minting a session with no identity behind it. *(Correctness.)*
- `issue_session()` reads every field with `.get()` and tolerates an absent `sub`. The
  session stays valid, authorization still works, only the profile lookup degrades —
  the correct severity for an optional field in the one function every credential class
  routes through. *(Safety.)*

**Take this forward:** if you change a shared helper, enumerate *every* caller before
running a subset. `issue_session` has two, and only one was obvious from the file that
motivated the change.

### 3.2 Account menu — a fix that was wrong the first time

The dropdown closed the instant the pointer moved toward it. First attempt removed the
handlers from the menu — **still broken**, because the *trigger button* also had
`onMouseLeave={stop}` and the menu sits below the button, so moving down crosses the
button's edge. My reasoning said it worked. It did not. Only a real browser caught it.

Fixed by removing all mouse/focus handlers; dismissal is owned solely by an
outside-click listener that ignores targets inside the trigger or the menu.

### 3.3 Avatar

A bare letter in an unstyled circle does not read as a button. Now: Google picture →
person silhouette → initial. The frame owns its own `rounded-full object-cover`, which
also fixed the *menu* avatar (outside the header button's `overflow-hidden`, so pictures
were square there).

### 3.4 Details page — rebuilt

Overflow bug fixed structurally: the hero breaks out of `<main>` padding so the backdrop
runs edge-to-edge **under** the sticky header. Measured `overlapPx: 0`, not eyeballed.

Synopsis moved under the actions in **italics** (Netflix/Apple TV convention), clamped
behind a More control. Crew facts fill the right-hand column. Cast is a scroll rail
with portraits + initials fallback. Trailer in a native `<dialog>`, iframe mounted only
when open.

Two **silent data bugs** found by rendering against the live API:
- `parseDetails()` accepted only a JSON *string*; the API sends `extended` as an
  **object**. Every extended field degraded to absent — no tagline, no cast, no
  directors — with no error anywhere.
- Backdrop URL built from `movie.tmdb_id`, bypassing the `backdrop_tmdb_id` the server
  gates on real artwork → **404 for every title without a backdrop**.

---

## 4. ⚠️ THE OPEN DECISION — 36 failing tests

```
38 failed, 852 passed, 28 skipped
```

(Was 41 before §3.1a; three auth failures were fixed at commit time. Baseline for
comparison is **12 failed / 877 passed** at `2ea7fb4` — those 12 were the
`google_auth` identity bug in §3.1, now fixed.)

| Source | Count | Nature |
|---|---|---|
| Legacy Jinja HTML assertions | **36** | Your decision |
| `test_startup_errors_when_on_without_secret` | 1 | Pre-existing, documented |
| `test_seek_preview_and_playback_advancement` | 1 | Selenium, needs live browser |

The 36 (`test_app.py` 26, `test_devices.py` 6, `test_system.py` 2, plus one each in
`test_manage.py` and `test_storage_retention.py`) assert on Jinja markup the React
migration deleted — `const filename`, `Total Devices`, `href="/devices"`. They receive
the SPA shell now. They test markup that no longer exists, not behaviour that broke.

**Do not delete them in bulk.** Split them first:

- **API assertions** (`/api/devices` etc.) still pass and are real coverage — keep.
- **HTML assertions** on migrated routes — port to the React equivalent where the
  behaviour still matters, retire where it is genuinely obsolete (old player CSS).

Options, with my recommendation:

- **A. Migrate the coverage** *(recommended)* — rewrite against SPA/components, retire
  obsolete assertions. Keeps the signal.
- **B. Restore Jinja behind a flag** — no coverage lost; two frontends to maintain.
- **C. Leave red** — cheapest today, trains everyone to ignore a red suite.

This was deliberately left for the owner: deciding how much old coverage is worth
salvaging is a judgement about the project, not a technical call.

---

## 5. Traps — read before you touch anything

**Never a bare `flutter test`.** Use `scripts/run_flutter_tests.ps1`. It purges
media_kit's orphaned temp state. Windows recycles PIDs, so a new test process can
inherit a dead run's pointer file and hang every await — measured 415 orphans causing
failures **including a `--concurrency=1` run**, so serial is not a fix.

**Ordinary Flutter tests must never reach the live server.**
`test/support/test_network_guard.dart` installs an allowlist `HttpOverrides`. The
sentinel is `http://test.invalid:8000` — deliberately non-loopback, because
`PlayerMediaResolver` skips loopback media hosts and would fall through to production.

**Ordinary Flutter tests must not call `MediaKit.ensureInitialized()`** unless they
genuinely need native playback.

**Test isolation.** `tests/conftest.py` redirects cache/DB/uploads **through the
environment before the app is imported**. Never resolve `conftest` by module name —
two files share that basename and whichever imports last wins. Never set
`MEDIA_SERVER_MEDIA_ROOT` at test-module import time.

**Live purges delete sibling tests' fixtures.** Any test calling
`purge_orphaned_caches(dry_run=False)` must own a dedicated cache root, established in
`setUp` — not import time. A green suite hid this exact bug.

**Verification is done by a model that did not write the artefact.** Different model,
different card. Route implementation and review to different models.

**`scripts/probe_android_api.py` is a guardrail, not a wish list.** It expects each
route's *contract*: `/api/cast/status` answers `400` when idle, `/api/app/*` answers
`404` when unpublished. Both are working routes. Do not "fix" them to 200.

---

## 6. Migration constraint (now executable)

The shipped Android app must keep working. Two facts make this safe, both verified:

- **It requests no HTML page.** No `WebView` anywhere in `lib/`. Its `AppRoutes`
  constants (`/home`, `/library`, `/player`, …) are `GoRoute` definitions for in-app
  navigation, not server URLs.
- **Its surface is 18 endpoints**: `/api/*`, `/media/`, `/hls/`, `/subtitles/`,
  `/poster/*`, `/tmdb-poster/`, `/tmdb-backdrop/`.

```powershell
python scripts/probe_android_api.py    # exits 1 on a break
```

Corollary: retiring a Jinja page **cannot** break the app, so §4 is a product
decision, not a compatibility one.

---

## 7. How to verify (do this; do not skip)

```powershell
# Frontend — build last, it is the served artefact
cd web; npm run typecheck; npx.cmd vitest run; npm run build

# Backend
.\venv\Scripts\python.exe -m py_compile app/__init__.py app/routes/pages.py app/routes/auth.py
.\venv\Scripts\python.exe -m pytest tests/

# Migration guardrail
python scripts/probe_android_api.py
```

**For UI work, render against the live API and measure.** Do not judge a layout from
the DOM. Concretely: assert `getBoundingClientRect()` on the header and the element you
moved, confirm `document.documentElement.scrollWidth === window.innerWidth`, and read
`console` errors. A page can look correct while logging a 404 — that is exactly how
the backdrop bug survived.

Two failures this handoff ran into, both from not doing that:
- A menu fix verified by *reasoning* shipped broken (§3.2).
- A page "rendered fine" while 404ing on every title without artwork (§3.4).

For hard isolation claims, snapshot library files, production `movies` rows and
`cache/hls` hashes before and after — a green suite is what hid the purge bug.

### Test-order and assertion traps

Three tests in this project were wrong in ways that only surface under some orderings.
All three are fixed; the patterns are not:

- **Scope an identity assertion by its natural key, not by email.** A test asserting
  "one row per user" counted by e-mail, so a row seeded by another module failed it
  purely on file ordering. `google_sub` is what `upsert_user()` keys on — use that.
- **Do not assert `Set-Cookie[0]`.** A response can legitimately carry several cookies.
  Assert the cookie you care about is *among* them; ordering is not a property worth
  pinning, and doing so turns any unrelated change into a failure.
- **Run the file you changed, in isolation.** See §3.1a. A green subset tells you
  nothing about a file you did not run.

---

## 8. Environment & operations

- Windows 11, Python 3.14.3 (`venv\`), Node 11, Flutter.
- NSSM service `MediaServer` + `Cloudflared`, both automatic. Restart with
  `restart_service.bat` (**UAC**). A bare `Restart-Service` is **not** sufficient —
  the NSSM wrapper keeps its environment block; use full Stop + Start.
- Credentials in `.env`. Never commit it.
- Storage: `E:` = app/DB/caches (fast SSD). `D:` = cold media, uploads, archive.
  `C:` unused.

---

## 9. Suggested next steps, in order

1. **Decide §4.** Highest value: a red suite erodes trust in every future signal.
2. **Restart the service** so the rebuilt `web/dist` and backend fixes are live.
3. **Sign out / sign in once.** The live session predates the `sub` fix, so profile
   data will not resolve until a fresh session exists.
4. **Migrate the remaining Python tests** the decision produces.
5. Update `docs/PROJECT_STATUS.md` §4 and `AGENTS.md` with the outcome.

---

## 10. Reference

| Path | What |
|---|---|
| `AGENTS.md` | **Authoritative invariants.** Read first. |
| `docs/PROJECT_STATUS.md` | Dated work log + open items |
| `docs/MIGRATION_STATUS.md` | Migration phase status |
| `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md` | Roadmap |
| `scripts/probe_android_api.py` | Android API guardrail |
| `web/src/features/media-details/` | Details page + cast rail |
| `app/services/google_auth.py` | Google OAuth, sessions, identity |
| `flutter_client/` | Android/Fire TV client |
| `.worktrees/t_ab424b2b` | Stale worktree; unrelated branch |

**Observatory vault:** `C:\Users\anis7\Documents\Obsidian Vault\Media Server\`
(`OBSIDIAN_VAULT_PATH`). Read *Memory Index* and *Gotchas & Pitfalls* before
non-trivial work; append to *Decisions Log* / *Verification Log* afterwards —
**append only, never rewrite another agent's entry.**