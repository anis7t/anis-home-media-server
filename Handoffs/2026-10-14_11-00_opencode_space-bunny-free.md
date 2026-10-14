# Handoff — Anis' Home Media Server

| | |
|---|---|
| **Date** | 2026-10-14 11:00 IST (05:30 UTC) |
| **Agent** | OpenCode |
| **Model** | space-bunny-free |
| **Workspace** | `E:\MediaServer` |
| **Branch** | `feat/react-web-frontend` — **not pushed**, ahead of `origin/feat/react-web-frontend` |
| **Code state** | `3afdc29` admin fix · `34f54ae` transcode fix · `9ea7f24` SPA routing · `ba0b9b2` legacy tests · `a311be4` SPA + deadlines. This document is the only change on top. |
| **Verified** | Python **904 passed / 2 failed**; frontend **91/91**; Android guardrail **18/18** |
| **Pushed** | **No** — pushing is reserved for the user |

> This header deliberately names the **code** commits rather than a single `HEAD`: a handoff
> that states its own hash is wrong the moment it is committed. The next handoff should cite
> the newest file in `Handoffs/`.

---

## Paste-ready prompt

Copy everything inside the block below to start the next session.

---

```
Continue work on Anis' Home Media Server at E:\MediaServer.

STATE
- Branch feat/react-web-frontend, ahead of origin (NOT pushed). Pushing is reserved for the user.
- Code state: 3afdc29 admin fix, 34f54ae transcode fix, 9ea7f24 SPA routing, ba0b9b2 legacy
  tests, a311be4 SPA redesign + request deadlines.
- Verified at HEAD: Python 904 passed / 2 failed (both documented below), frontend 91/91,
  tsc + oxlint clean, Android guardrail 18/18.
- Live host: MediaServer + Cloudflared NSSM services. Server on 127.0.0.1:8000,
  published at https://media.anisparvez.in via a Cloudflare tunnel.
- You WILL need to restart the service (scripts\restart_service.bat, ELEVATED) after any
  edit under app/ - Waitress caches bytecode and does not reload.
- You WILL need `npm run build` after any edit under web/src - web/dist is the served
  artefact and nothing else rebuilds it.

READ FIRST, IN THIS ORDER
- AGENTS.md            - authoritative invariants, non-negotiable.
- Handoffs\2026-10-14_11-00_opencode_space-bunny-free.md  - this document.
- docs\MIGRATION_STATUS.md          - where the P0..P7 migration stands.
- docs\PROJECT_STATUS.md            - dated work log, newest first (section 0).
- docs\FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md - the migration's shape and gates.

THE MIGRATION IS NOT WHAT YOU MIGHT ASSUME
- P0 audit, P1 OpenAPI contracts, P2 React web frontend: done (P2 complete against Flask).
- P3 PostgreSQL: code EXISTS (app/db.py has migrations, advisory locks, pool lifecycle)
  but has NEVER been run under authorization. Treat it as untested code, not progress.
- P4-P7 (Rust Axum API, Rust media, Rust transcoder, cutover): NOT STARTED. No rust/,
  no Cargo.toml.
- Jinja templates are GONE. Every page has a React equivalent. This is done, not pending.

TOP RISK, AND IT IS NOT A CODE RISK
- There is no documented backup, no restore drill and no rollback window for a machine
  holding a film library and a multi-day transcode pipeline. That is the largest
  unmitigated risk in the project and it is not on anyone's critical path.

TWO KNOWN FAILING TESTS - do not "fix" these casually
- tests/test_auth_foundation.py::TestSecretKey::test_startup_errors_when_on_without_secret
  is pre-existing and documented.
- tests/test_selenium_seek_playback.py::test_seek_preview_and_playback_advancement is the
  LAST unmigrated casualty of the Jinja -> React migration. It loads /, receives the SPA
  shell, then raises NoSuchElement on removed markup. It needs the same porting the other
  36 legacy tests received. This is next step #1.
- KNOWN FLAKE: tests/test_app.py::test_player_touch_gestures_and_double_tap_ripples failed
  once in 3 full-suite runs and passed in the other two. Its body is byte-identical to four
  sibling tests that always pass, and it passes 58/58 in isolation. Root cause NOT found.
  If it recurs, that is where to start.

WARNINGS THAT WILL BITE YOU
1. NEVER bare `flutter test` - use scripts\run_flutter_tests.ps1. It purges media_kit's
   orphaned temp state; without it Windows PID recycling makes a new test process inherit
   a dead run's pointer file and hang every await. Measured 415 orphans causing failures
   INCLUDING a --concurrency=1 run, so serial is NOT a fix.
2. Never resolve `conftest` by module name. tests/conftest.py and tests/integration/conftest.py
   share a basename, neither dir has __init__.py, so pytest registers both as `conftest` and
   whichever imports last wins. A guard silently fell back to its own set and 18 refusal
   tests failed WHILE THE SUITE STAYED GREEN. Import conftest data as a fixture, never as
   a module.
3. A test module must not configure the environment at import time. Setting
   MEDIA_SERVER_MEDIA_ROOT at import then importing `app` only works if that file happens
   to be the first to import app. Import order must never decide where a test writes.
4. Any test calling purge_orphaned_caches(dry_run=False) must own a dedicated cache root,
   established in setUp - never at import time. A directory planted by an unrelated test
   was destroyed by another test's purge while the whole suite stayed green.
5. The Admin PIN fails CLOSED and has no default. A hard-coded default existed and was
   removed: on a host published to the internet it meant anyone who guessed four digits
   could delete the library. Never reintroduce a default, never accept the PIN from a query
   string, and remember a closed probe is not a closed door.
6. _is_hls_truly_complete() is a PREDICATE and must never write. A function named is_*complete
   has no business mutating the thing it is judging. Sealing a cache is
   scripts\hls_restore_endlist.py, which counts frames first.
7. Frame accounting is the only trustworthy content measure. Never write ENDLIST from a
   duration ratio; never call source_video_duration(path, fallback=<anything but None>);
   never walk segment indices densely from 0. AGENTS.md section 6 has the measurements.
8. A naive SPA catch-all steals API routes. app/__init__.py uses SpaPathConverter with a
   negative lookahead for exactly this reason - do not simplify it back to /<path:path>.
9. Measure UI in a browser, never by reasoning. Twice here a change verified by inspection
   shipped broken: an account menu that closed on hover, and a page that rendered fine
   while 404ing on every title without artwork.
10. A green subset is not evidence. The QR pairing regression survived because the one test
    file that would have caught it (test_auth_tokens.py) was never run in isolation.
11. Verification must be done by a different model/harness than wrote the artefact. This is
    a project rule, not a suggestion.
12. PowerShell has no heredocs and rejects `&&`. Write multi-line content to a file, then
    read it back - the write tool has silently mangled large Python before.
13. docs/PROJECT_STATUS.md has double-mangled em-dashes from older tooling. Anchor edits on
    dash-free substrings and verify after writing.

VERIFY BEFORE YOU TRUST ANY OF IT
  .\venv\Scripts\python.exe -m pytest tests\
  cd web; npm run typecheck; npx.cmd vitest run; npm run build
  python scripts\probe_android_api.py
The probe expects each route's CONTRACT, not a 200: /api/cast/status answers 400 when idle
and /api/app/* answers 404 when nothing is published. Both are working routes. Do not
"fix" them to 200.

PUSHING IS THE USER'S CALL.
```

---

## 1. What this project is

`anis7t/media-server` — a self-hosted film library on one Windows 11 machine.

Three consumers share one Flask backend:

| Consumer | Surface | Notes |
|---|---|---|
| **Web UI** | React SPA in `web/` → `web/dist`, served by Flask | Single origin, so Google Sign-In's cookie works |
| **Android / Fire TV** | Flutter in `flutter_client/` | **Shipped and working.** Requests **no HTML** — no WebView anywhere |
| **Cast / DLNA** | Samsung TVs etc. | Byte-range + HLS, CORS-enabled for receivers |

Behind them: a dual-GPU (RX 560X discrete + Vega 8 integrated) FFmpeg transcoding pipeline
with its own HLS cache-integrity machinery, seek-preview thumbnails, TMDb metadata, Google
Sign-In, device presence, and a Cloudflare tunnel publishing `media.anisparvez.in`.

This is a **single-machine personal deployment**, not a multi-tenant product. Throughput is
bounded by upload bandwidth, and "production" means "the one house it runs in".

---

## 2. Commands

```powershell
# Backend
.\venv\Scripts\python.exe -m py_compile app\config.py app\services\transcode_service.py
.\venv\Scripts\python.exe -m pytest tests\        # ~5-7 min

# Frontend  (cd web)
npm run typecheck        # tsc -b
npm run lint             # oxlint
npx.cmd vitest run       # 91 tests
npm run build            # REQUIRED - see below

# Flutter  (cd flutter_client)
.\scripts\run_flutter_tests.ps1    # NEVER bare `flutter test`

# Migration guardrail
python scripts\probe_android_api.py     # exits 1 on a break
```

### ⚠️ `web/dist` is the served artefact

Flask serves `web/dist/index.html` and its hashed assets. **Any change under `web/src` is
invisible until `npm run build` runs.** Restarting the service does not rebuild it. This is
the most common way to "fix" the UI and see no change.

### ⚠️ Backend edits need an elevated service restart

Waitress caches Python bytecode in memory and does not auto-reload. After editing anything
under `app/`:

```
e:\MediaServer\scripts\restart_service.bat
```

Run it **elevated** (UAC). A bare `Restart-Service MediaServer` is *not* sufficient — the
NSSM wrapper holds its own environment block; use a full Stop + Start.

---

## 3. Where we are in the migration

Source of truth: `docs/MIGRATION_STATUS.md` §3 (progress matrix), with the shape and exit
gates in `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`.

| Phase | Scope | Status | Notes |
|---|---|---|---|
| **P0** | Architecture audit | **Complete** | Evidence-based inventory |
| **P1** | OpenAPI spec + contract tests | **Complete** *(reported)* | `docs/openapi.yaml`, `tests/test_api_contracts.py`. Known drift — see `web/src/lib/api/spec-drift.ts` |
| **P2** | React web frontend | **Complete for the Flask backend** | Every Jinja page ported. Details below |
| **P3.1** | PostgreSQL adapter | Partially complete *(reported)* | `app/db.py`: migrations, advisory locks, pool lifecycle |
| **P3.2–3.3** | PG integration tests, timestamp compat | Partially complete *(reported)* | |
| **P3.4–3.8** | Test isolation, write guards, cache hardening | Partially complete *(reported)* | |
| **P4** | Rust API foundation (Axum) | **Not started** | No `rust/`, no `Cargo.toml` |
| **P5** | Rust media / playback / streaming | **Not started** | |
| **P6** | Rust transcoding worker | **Not started** | |
| **P7** | Cutover, hardening, Flask retirement | **Not started** | Blocked by P4–P6 |
| **Rollback / data safety** | Backup + demonstrated restore | **Blocked — real gap** | No backup, no restore drill, no rollback window exists |
| **Acceptance testing** | Per-phase exit gates | **Blocked** | Only P0/P1 have artifacts |

**Read the *(reported)* marker literally.** P3 exists as code that has never been executed
under authorization. It is untested code, not progress. If your task touches `app/db.py`,
you are in the least-documented, least-tested part of this repository.

### P2 in detail — the part you will actually touch

Routes, from `web/src/main.tsx`:

```
/  /movie/*  /watch/*  /account  /manage  /library-manage
/devices  /clients  /manual  /help  /how-to-use
```

Legacy aliases (`/library-manage`, `/clients`, `/help`, `/how-to-use`) keep old bookmarks and
the manual working. `*` redirects to `/`. Jinja templates are **gone**; `pages.py` is down to
four routes (manifest, download, icon, sw).

> **Corollary that matters for planning:** because the Android app never touched the Jinja
> pages, retiring them could not break it. Retiring a page is a *product* decision, not a
> compatibility constraint. What must not be deleted is the **coverage** behind those pages.

### The SQLite → PostgreSQL question

P3 is real work that exists but has never been exercised. Do not assume the database layer
is migration-ready. Verify before building on it.

---

## 4. What was delivered in this session

Six commits on top of `3fb0473`, all measured — see §6.

### 4.1 Request deadlines and retry (`a311be4`)

`request()` had **no timeout** and neither did `useAsync`. A fetch that never settled
produced an **indefinite skeleton with no error and no recovery short of a page reload** —
exactly how a "stuck page" presents.

Budgets are measured, not chosen:

| Observation | Cost |
|---|---|
| Cold `/api/movie/{filename}`, unseen title | 2.5s |
| Cold control title, first request | 7.79s |
| Ten simultaneous cold details requests | 3.5s wall |
| One request during a service restart | **>30s (timed out)** |

Hence `DEFAULT_TIMEOUT_MS = 20_000`, and `MEDIA_PROBE_TIMEOUT_MS = 45_000` for the three
media-probing endpoints, which would otherwise fail the slowest titles *deterministically*
rather than by accident. `/api/movies` keeps the 20s default.

Design points worth preserving:

- One `AbortController` covers both reasons to stop (caller cancellation, deadline), wired
  **by hand** rather than via `AbortSignal.any()` so no polyfill ships.
- `timedOut` is checked **before** rethrowing, so a deadline reports as `ApiTimeoutError`
  instead of the platform's opaque "The operation was aborted".
- A **caller** abort stays an `AbortError`. Reported as a timeout, every route change away
  from a slow page would flash a spurious "server took too long" on the way out.
- The timer is cleared in `finally`, so a response that already arrived is never
  retroactively converted into a timeout.

`useAsync` gained `reload()`; `StateMessage` renders **Try again**. The failure state is no
longer terminal. Verified in a browser, not by inspection: first request aborted → alert and
button appeared → button clicked → request re-issued → alert cleared → content rendered, with
no reload.

### 4.2 Two defects caught before commit (`3afdc29`, `34f54ae`)

Both were in uncommitted work inherited from a prior session. Both are fixed.

**Hard-coded default Admin PIN.** `get_setting('admin_pin', '6361')`. On a host published to
the internet through the Cloudflare tunnel, that is **permanent unauthenticated access** to
everything behind `@require_admin` — *including deleting the library*, purging caches, moving
originals into the archive, and rewriting the retention policy. Four digits against a route
with no rate limit.

Now fails closed via `_configured_admin_pin()` → `get_setting('admin_pin', '')`. Unset means
the PIN channel is **closed**, leaving only a Google admin session — which is also what
`/api/admin/status` already reported `has_pin` against, so the two can no longer disagree.
The PIN is also no longer accepted from `?pin=`: a secret in a query string lands in Waitress
access logs, Cloudflare's edge logs, browser history and `Referer` headers.

**`_is_hls_truly_complete()` wrote.** It was appending `#EXT-X-ENDLIST` when
`cumulative / source_duration >= 0.98`. Three problems:

- The measure is the one this project **measured to be untrustworthy** — a cache read 100%
  by duration while missing 277.2s of frames across 101 chunks.
- It would seal precisely the frame-deficient caches the frame accounting exists to catch.
- It wrote from inside a predicate, in a 1Hz callback, unserialised and non-atomically —
  violating `_PLAYLIST_WRITE_LOCK` + `write_text_atomic`.

Reverted; the function is a predicate again with the reason at the branch. Sealing a
verified-complete cache remains `scripts/hls_restore_endlist.py`, which counts frames first.
The same commit **kept** a real fix: Matroska tags are locale-suffixed (`DURATION-eng`), so
`tags.get('DURATION')` missed them and `source_video_duration()` fell through to a container
duration — which is exactly the denominator this module must not use.

### 4.3 SPA routing isolation (`9ea7f24`)

The catch-all was `/<path:path>`. Werkzeug prioritises rules matching the requested *method*
over returning 405 on non-matching blueprint routes, so it intercepted GETs on POST-only and
unknown API routes, answering 200 `index.html` where JSON or 404 was owed. Replaced with
`SpaPathConverter` and a negative lookahead.

### 4.4 Legacy test migration (`ba0b9b2`)

Resolved the open decision from the previous handoff. The 36 failing tests in `test_app.py`
(26), `test_devices.py` (6), `test_system.py` (2), plus one each in `test_manage.py` and
`test_storage_retention.py`, asserted on deleted Jinja markup. Each was re-pointed at what it
was actually protecting — SPA shell status for page routes, real JSON contracts for API
routes. `test_app.py` shrank by ~174 net lines because most deleted content was HTML-shape
assertion with no behavioural content left.

### 4.5 Documentation

This document, three new invariant blocks in `AGENTS.md` (§4 admin authorisation, §6
predicate-must-not-write and frontend deadlines), a dated `PROJECT_STATUS.md` entry, and a
corrected P2 row in `MIGRATION_STATUS.md`. `.gitignore` now covers SQLite WAL sidecars.

---

## 5. Security posture — read before shipping anything

This server is reachable from the **public internet** at `media.anisparvez.in`.

- Auth enforcement is **OFF** (`MEDIA_SERVER_AUTH` unset). Deliberate, so TV and Flutter
  clients are not 401'd — and it means **the stable hostname is not authentication.**
  Anyone with the URL reaches any unauthenticated route.
- Routes behind `@require_admin` are the most destructive surface in the app:
  `/api/media/<path>` DELETE, `/api/storage/purge-orphans`, `/api/storage/archive/<path>`,
  `/api/storage/settings` POST, `/api/admin/pin`. Any weakening of `is_admin_authorized()`
  is critical.
- The Admin PIN has no default and fails closed. Setting one is a deliberate act by an admin.
- **Add access control before any wider sharing.** Open roadmap item, not a done item.

---

## 6. Current state, honestly

| Suite | Result |
|---|---|
| `tsc -b` | clean |
| `oxlint` (changed files) | clean |
| `vitest` | **91 passed** (11 files) |
| `pytest tests/` | **904 passed, 2 failed, 28 skipped** (~4:41) |
| `scripts/probe_android_api.py` | **18/18 per contract** |

Three full-suite runs were taken at this tree: 903/3, 904/1 (Selenium deselected), and
904/2. The consistent result is **the two documented failures below**.

### The 2 failures

1. **`test_auth_foundation.py::TestSecretKey::test_startup_errors_when_on_without_secret`** —
   pre-existing and documented. Unrelated to the migration.
2. **`test_selenium_seek_playback.py::test_seek_preview_and_playback_advancement`** — **the
   last unmigrated casualty.** Not merely "needs a browser": it loads `/`, receives the SPA
   shell, then raises `NoSuchElementException` on removed markup. It needs the same porting
   the other 36 received, and was missed because a Selenium test reads as environmental
   rather than as a contract failure.

### Known flake, root cause unknown

`tests/test_app.py::test_player_touch_gestures_and_double_tap_ripples` failed **once in three**
full-suite runs. Evidence gathered:

- `tests/test_app.py` alone: **58/58**.
- The four files preceding it in collection order: **98/98**.
- Full suite: passed, failed, passed.
- Its body is **byte-identical** to four sibling tests that always pass, all asserting
  `200` + `<div id="root">` on `/watch/Example.2026.mp4`.
- `/watch` and `/movie` have **no url_map rules at all** — they are SPA catch-all — and a
  clean app returns `200 text/html` with the root div every time. So it is not a routing
  defect.

Root cause **not** established. If it recurs, start there; the identical-body observation
says the cause is positional or environmental, not specific to that test.

### Known rough edges

- **`web/src/features/manage/ManagePage.tsx` is ~45 KB in one component.** Works and is
  tested, but the one file in `web/src` well past the size where editing is safe. Split it
  before adding to it.
- **`ManagePage.tsx` bypasses the typed API client**, calling bare `fetch()` (`/api/movies`,
  `/api/storage/settings`, `/api/storage/audit`, `/api/admin/verify`,
  `/api/storage/purge-orphans`, `/api/scan`, and the delete call — roughly lines 116–301).
  **Those requests carry no deadline.** Risk is lower than it sounds — they are user-initiated,
  so a hang leaves a spinner, not an empty page — but the two most destructive routes are
  among them. Deliberately not refactored here: a late rewrite of an unfamiliar 45 KB
  component controlling media deletion is a worse risk than the gap it closes.
- **`docs/openapi.yaml` has drifted** from the real API. Generated `TechnicalSpecs` declares
  7 of the 10 keys the server sends, and spells one `filesize` against the real `file_size`.
  Recorded in `web/src/lib/api/spec-drift.ts`; the spec is deliberately not hand-edited,
  because generated types derive from it.
- **`docs/PROJECT_STATUS.md` is ~152 KB** with some double-mangled em-dashes from older
  tooling. Anchor edits on dash-free substrings and verify after writing.
- **PowerShell has no heredocs and rejects `&&`.** Use script files or `;`. Write multi-line
  content to a file and read it back — the write tool has silently mangled large Python
  before.

---

## 7. Traps

The full set is in `AGENTS.md`. These are the ones most likely to catch a new harness.

**Never run a bare `flutter test`.** Use `scripts\run_flutter_tests.ps1`. It purges media_kit's
orphaned temp state. Windows recycles PIDs, so a new test process can inherit a dead run's
pointer file and hang every `await` — measured 415 orphans causing failures *including a
`--concurrency=1` run*. Serial is not a fix.

**Never resolve `conftest` by module name.** `tests/conftest.py` and
`tests/integration/conftest.py` share a basename and neither directory has `__init__.py`, so
pytest registers both as module `conftest` and whichever imports last wins. A write guard
silently fell back to its own set and 18 refusal tests failed **while the suite stayed green**.
Import conftest data as a fixture, never as a module.

**A test module must not configure the environment at import time.** Setting
`MEDIA_SERVER_MEDIA_ROOT` at import then importing `app` only works if that file happens to be
the first to import `app`. 36 tests once failed with 404s for exactly this reason while the
same file passed 58/58 alone. Import order must never decide where a test writes.

**Live purges delete sibling tests' fixtures.** Any test calling
`purge_orphaned_caches(dry_run=False)` must own a dedicated cache root established in
`setUp`. A directory planted by an unrelated test was destroyed by another test's purge
**while the whole suite stayed green** — a green suite is exactly what hid it.

**A naive SPA catch-all steals API routes.** Use `SpaPathConverter` with a negative lookahead.

**Frame accounting is the only trustworthy content measure.** Never write ENDLIST from a
duration ratio; never call `source_video_duration(path, fallback=<anything but None>)`; never
walk segment indices densely from 0. `AGENTS.md` §6 has the measurement behind each.

**Measure UI in a browser; do not reason about it.** Twice recently, a change verified by
reasoning shipped broken — an account menu that closed on hover, and a page that "rendered
fine" while 404ing on every title without artwork. Assert `getBoundingClientRect()`, check
`document.documentElement.scrollWidth === window.innerWidth`, read `console`.

**A green subset is not evidence.** The QR pairing regression (`96ecc56`) survived because the
one file that would have caught it was never run in isolation. Run the file you changed.

**Verification must be done by a model that did not write the artefact.** Project rule. Route
implementation and review to different models/harnesses.

---

## 8. Ranked next steps

1. **Port `test_selenium_seek_playback.py`** — the last migration casualty. Small, bounded,
   and it closes the test migration for good.
2. **Set an Admin PIN deliberately.** The channel is closed until an admin does; that is
   correct, but it should be a decision rather than an accident.
3. **Write down a backup and a restore drill.** No backup, no restore drill, no rollback
   window exists for a machine holding a film library and a multi-day transcode pipeline.
   **This is the largest unmitigated risk in the project.**
4. **Decide on authentication before any wider sharing** (§5).
5. **Verify P3 or mark it unverified.** The PostgreSQL work exists but has never been run
   under authorization; treat it as untested code.
6. **Route `ManagePage.tsx` through the typed client**, then split it.
7. **Investigate the `test_app.py` flake** if it recurs.

---

## 9. Environment & operations

- **Windows 11**, Python 3.14.3 in `venv\`, Node 11, Flutter.
- Services: `MediaServer` (Waitress via NSSM, 16 threads) and `Cloudflared`, both automatic,
  crash-restarting, 10 MB log rotation. Restart via `scripts\restart_service.bat` (elevated).
- **Storage is tiered.** `E:` = application, SQLite, HLS cache, seek previews (fast SSD).
  `D:` = cold media, upload staging, `.archive`, `.deleted` (high capacity). `C:` unused.
  All media/cache/subtitle paths must resolve across `config.get_media_roots()`.
- Secrets in `.env` — never commit it.
- **`web/dist` and `media.db*` are gitignored by design.** A missing `web/dist` disables the
  SPA routes entirely (`create_app` only registers them if `index.html` exists).
- **Observatory vault** (project memory):
  `C:\Users\anis7\Documents\Obsidian Vault\Media Server\` (`OBSIDIAN_VAULT_PATH`).
  Read *Memory Index* and *Gotchas & Pitfalls* before non-trivial work; append dated entries to
  *Decisions Log* / *Verification Log* afterwards. **Append only — never rewrite another
  agent's entry.**

---

## 10. Document map

| Document | What it holds | Read it when |
|---|---|---|
| **`AGENTS.md`** | **Authoritative invariants.** HLS cache integrity, frame accounting, DLNA/Cast rules, test-isolation landmines, admin authorisation, frontend deadlines | **Every session, before editing** |
| **`docs/MIGRATION_STATUS.md`** | Phase-by-phase P0–P7 matrix, repository state, risks, recommended resumption | Planning anything beyond the current Flask backend |
| **`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`** | The migration's shape, sequence items and per-phase exit gates | Understanding *why* a phase exists |
| **`docs/PROJECT_STATUS.md`** | Dated work log, newest first, with the reasoning behind each change | Looking for "why was this done this way" |
| **`docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md`** | The measurements behind every transcoder constant | Touching the pipeline |
| **`docs/FLUTTER_CLIENT_STATUS.md`** | Flutter client state, its test hazards, media_kit analysis | Touching `flutter_client/` |
| **`docs/AUTHENTICATION_PLAN.md`** | Auth design and roadmap | Touching auth |
| **`docs/FLUTTER_PLAYER_PARITY.md`** | Player feature parity with the web player | Player work |
| **`docs/DEVELOPMENT_STATUS.md`** | Current Windows/AMF and persistent-service state | Ops |
| **`docs/WINDOWS_SETUP.md`** | Host setup | Rebuilding the host |
| **`docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`** | Tunnel history and named-tunnel config | Remote-access problems |
| **`docs/openapi.yaml`** | API spec (has known drift — see `spec-drift.ts`) | Client work |
| **`docs/MANUAL.md`** | Offline user guide | User-facing copy |
| **`Handoffs/`** | Dated handoffs, newest last | Session start — read the newest |

### Key code paths

| Path | What |
|---|---|
| `web/src/main.tsx` | Route map |
| `web/src/lib/api/client.ts` | Typed client, request deadlines |
| `web/src/lib/useAsync.ts` | Loading/error/empty + retry |
| `web/src/lib/api/spec-drift.ts` | Where the real API differs from `openapi.yaml` |
| `app/__init__.py` | App factory, SPA catch-all, `SpaPathConverter` |
| `app/routes/api.py` | Admin authorisation + most API surface |
| `app/services/transcode_service.py` | Transcoding, HLS cache, ENDLIST logic |
| `app/services/google_auth.py` | Google OAuth, sessions, identity |
| `tests/conftest.py` | Test isolation — redirects cache/DB/uploads via env before import |
| `scripts/probe_android_api.py` | Executable Android-client guardrail |
| `scripts/hls_restore_endlist.py` | Frame-counted ENDLIST sealing (the sanctioned tool) |
| `flutter_client/` | Android / Fire TV app |