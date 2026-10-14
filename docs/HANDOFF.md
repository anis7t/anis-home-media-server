# Handoff — Media Server

**For any AI coding harness taking over this repository.**

Prepared 2026-10-14 · branch `feat/react-web-frontend` · Windows host, Flask + React + Flutter

---

## 0. Read this first

Three files are load-bearing and disagree with each other in places. Trust order:

| File | Role |
|---|---|
| **`AGENTS.md`** | Authoritative invariants. Non-negotiable. Carries knowledge that cost real time and real data to acquire. |
| **`docs/PROJECT_STATUS.md`** | Dated work log (152 KB, newest first). The narrative record. |
| **`docs/MIGRATION_STATUS.md`** | Where the multi-year migration stands, phase by phase. |

This document is the orientation layer: what the project *is*, what state it is in, and what
will bite you. It does not replace `AGENTS.md`.

**Verify anything you are told.** Several items below are explicitly labelled *reported* —
they come from prior sessions and have not been re-verified under this harness. Re-measure
before acting on them.

---

## 1. What this project is

`anis7t/media-server` — a self-hosted film library, running on one Windows 11 machine.

Three consumers share one backend:

- **Web UI** — React SPA in `web/`, built to `web/dist`, served by Flask.
- **Android / Fire TV app** — Flutter in `flutter_client/`. A shipped, working consumer.
  It talks only to `/api/*`, `/media/`, `/hls/`, `/subtitles/`, `/poster/*`,
  `/tmdb-poster/`, `/tmdb-backdrop/`. **It has no WebView and requests no HTML.**
- **Cast/DLNA renderers** — Samsung TVs etc., pulling bytes and HLS.

Behind them: a dual-GPU (RX 560X + Vega 8) FFmpeg transcoding pipeline with its own HLS
cache integrity machinery, a seek-preview thumbnail service, TMDb metadata, Google
Sign-In, device presence, and a Cloudflare tunnel publishing `media.anisparvez.in`.

This is a **single-machine personal deployment**, not a multi-tenant product. That matters:
throughput tuning is bounded by upload bandwidth, and "production" means "the one house it
runs in".

---

## 2. Commands

```powershell
# Backend
.\venv\Scripts\python.exe -m py_compile app\config.py app\services\transcode_service.py
.\venv\Scripts\python.exe -m pytest tests\            # ~6 min, 902 passed / 2 failed

# Frontend  (cd web)
npm run typecheck        # tsc -b
npm run lint             # oxlint
npx.cmd vitest run       # 91 tests, ~15s
npm run build            # REQUIRED — see below

# Migration guardrail — the shipped Android app's contract, executable
python scripts\probe_android_api.py     # exits 1 on a break
```

### ⚠️ `web/dist` is the served artefact

Flask serves `web/dist/index.html` and its hashed assets. **Any change under `web/src` is
invisible until `npm run build` runs.** This is the single most common way to "fix" the UI
and see no change. Restarting the service does *not* rebuild it.

### ⚠️ Backend edits need a service restart

Waitress caches Python bytecode in memory and does not auto-reload. After editing anything
under `app/`, the service must be restarted or you will be debugging stale code.

```
e:\MediaServer\scripts\restart_service.bat
```

Run it **elevated** (UAC). A bare `Restart-Service MediaServer` is *not* sufficient — the
NSSM wrapper holds its own environment block; use a full Stop + Start.

---

## 3. Where we are in the migration

The project is mid-way through a long migration whose goal is Flask → Rust with a React
frontend and PostgreSQL. **Read this section before assuming anything is unfinished.**

| Phase | Scope | Status | Notes |
|---|---|---|---|
| **P0** | Architecture audit | **Complete** | Evidence-based inventory. |
| **P1** | OpenAPI spec + contract tests | **Complete** *(reported)* | `docs/openapi.yaml`, `tests/test_api_contracts.py`. Has known drift against reality — see `web/src/lib/api/spec-drift.ts`. |
| **P2** | React web frontend | **Complete for the Flask backend** | Every Jinja page now has a React equivalent. Details below. |
| **P3.1** | PostgreSQL adapter | Partially complete *(reported)* | `app/db.py` has migrations, advisory locks, pool lifecycle. Cutover not done. |
| **P3.2–3.3** | PG integration tests, timestamp compat | Partially complete *(reported)* | |
| **P3.4–3.8** | Test isolation, write guards, cache hardening | Partially complete *(reported)* | Never executed under authorization in the recorded history. |
| **P4** | Rust API foundation (Axum) | **Not started** | No `rust/`, no `Cargo.toml`. |
| **P5** | Rust media/playback/streaming | **Not started** | |
| **P6** | Rust transcoding worker | **Not started** | |
| **P7** | Cutover, hardening, Flask retirement | **Not started** | Blocked by P4–P6. |
| **Rollback / data safety** | Backup + demonstrated restore | **Blocked — and this is a real gap** | No documented backup, restore drill, or rollback window exists. |
| **Acceptance testing** | Per-phase exit gates | **Blocked** | Only P0/P1 have artifacts. |

### P2 in detail (the part you will actually touch)

The web frontend is **done against the current Flask backend**. Routes in
`web/src/main.tsx`:

```
/  /movie/*  /watch/*  /account  /manage  /library-manage  /devices  /clients  /manual  /help  /how-to-use
```

Legacy aliases (`/library-manage`, `/clients`, `/help`, `/how-to-use`) exist so old bookmarks
and the manual keep working. `*` redirects to `/`.

Jinja templates are **gone**. `pages.py` is stripped to four routes (manifest, download,
icon, sw).

> **Corollary that matters for planning:** because the Android app never touched the Jinja
> pages, retiring them could not break it. Retiring a page is a *product* decision, not a
> compatibility constraint. What must not be deleted is the **coverage** behind those pages.

### The SQLite → PostgreSQL question

P3 is real work that exists but has never been exercised under authorization. **Do not assume
the database layer is migration-ready.** Treat any claim about P3 as unverified until you have
run it yourself. If your task touches `app/db.py`, you are in the least-documented, least-tested
part of the repository.

---

## 4. What was delivered recently

Three sessions' work, all now committed on `feat/react-web-frontend`.

### 4.1 Auth identity (commit `96ecc56`)

Three defects in "who is this caller?":

- **Profile never resolved.** `resolve_identity()` used the **email** as the identity subject,
  so `/api/auth/me` queried `users WHERE google_sub = <email>`. `google_sub` is Google's stable
  subject id and is never an email, so the lookup could never match and `name`/`picture_url`
  were permanently `NULL`. The session now carries `sub`.
- **Silent profile erasure.** `upsert_user()` overwrote name/picture on every sign-in; now `COALESCE`.
- **Device cookie lost on SPA pages.** The catch-all meant `pages_bp`'s `after_request` stopped
  running for `/`, so `ms_device_id` vanished. Stamping moved to app level.

**And a regression the fix introduced:** adding `sub` made `issue_session()` raise `KeyError`
for the **QR pairing** route, which passes only id/email/role. Pairing returned 500. It was
caught only because `test_auth_tokens.py` was finally run in isolation — "the auth suite is
green" had been true of a *different file set*. Fixed by `get_user_by_id()` (correctness) and
`.get()` in `issue_session` (safety). These are not redundant.

### 4.2 React redesign (commit `1b16f56`, continued)

Header account menu, avatar affordance (Google picture → person glyph, never a bare letter),
details page rebuild (hero overlap fixed structurally — measured `overlapPx: 0`), italic
synopsis in the hero, cast rail with hover-revealed arrows, trailer in a native `<dialog>`.

Two silent data bugs found by rendering against the live API: `parseDetails()` accepted only a
JSON *string* while the API sends `extended` as an **object** (so all cast/crew/tagline
silently vanished), and the backdrop URL was built from `movie.tmdb_id` instead of the
gated `backdrop_tmdb_id` (404 for every title without artwork).

### 4.3 Page migration + test porting (prior session)

All remaining pages ported. The **36 legacy Jinja HTML assertions were migrated** to assert SPA
shell status and real API contracts. This is what moved the Python suite from 38 failures to 2.

Also introduced `SpaPathConverter` — see the trap in §6.

### 4.4 Request deadlines and retry (most recent)

`request()` had no timeout and `useAsync` none either, so **a hung fetch was indistinguishable
from a slow one**: indefinite skeleton, no error, no recovery short of a reload.

Budgets are measured, not guessed — cold `/api/movie/{filename}` costs 2.5–8s (the route
probes the file server-side), 10 simultaneous cold requests finish in ~3.5s wall, and one
request was observed exceeding 30s during a service restart. Hence `DEFAULT_TIMEOUT_MS = 20_000`
and `MEDIA_PROBE_TIMEOUT_MS = 45_000` for the media-probing endpoints.

`useAsync` gained `reload()`; `StateMessage` renders **Try again**. Verified in a real browser:
abort → error state → retry → recovered, no reload.

### 4.5 Two defects caught before commit

Both were in uncommitted work inherited from a prior session. Both are now fixed; see §5 for
why they matter.

- **Hard-coded default Admin PIN `'6361'`** in `app/routes/api.py`. On a host published to the
  internet, this is permanent unauthenticated access to everything behind `@require_admin` —
  *including deleting the library*. Now fails closed (`get_setting('admin_pin', '')`).
- **`_is_hls_truly_complete()` wrote `#EXT-X-ENDLIST`** from a duration ratio, inside a 1Hz
  callback, unserialised. Label arithmetic is the exact measure this project proved untrustworthy
  (a cache read 100% by duration while missing 277.2s of frames across 101 chunks). Reverted.

---

## 5. Security posture — read before shipping anything

This server is reachable from the **public internet** through `media.anisparvez.in`.

- Auth enforcement is currently **OFF** (`MEDIA_SERVER_AUTH` unset). This is deliberate so the
  TV and Flutter clients are not 401'd, and it means **the stable hostname is not
  authentication**. Anyone with the URL can reach any unauthenticated route.
- Routes behind `@require_admin` (`/api/media/<path>` DELETE, `/api/storage/purge-orphans`,
  `/api/storage/archive/<path>`, `/api/storage/settings` POST, `/api/admin/pin`) are the most
  destructive surface in the app. Treat any weakening of `is_admin_authorized()` as critical.
- The Admin PIN **has no default and fails closed**. Setting one is the admin's deliberate act
  via a Google admin session. See the invariants in `AGENTS.md` §4.
- **Add access control before any wider sharing.** This is an open roadmap item, not a done item.

---

## 6. Traps

These are the things that have already cost time. `AGENTS.md` has the full set; these are the
ones most likely to catch a new harness.

**Never run a bare `flutter test`.** Use `scripts\run_flutter_tests.ps1`. It purges media_kit's
orphaned temp state. Windows recycles PIDs, so a new test process can inherit a dead run's
pointer file and hang every `await` — measured 415 orphans causing failures *including a
`--concurrency=1` run*. Serial is not a fix.

**Never resolve `conftest` by module name.** `tests/conftest.py` and `tests/integration/conftest.py`
share a basename, neither dir has `__init__.py`, so pytest registers both as module `conftest` and
whichever imports last wins. A guard silently fell back to its own set and 18 refusal tests
failed *while the suite stayed green*. Import conftest data as a fixture, never as a module.

**A test module must not configure the environment at import time.** Setting
`MEDIA_SERVER_MEDIA_ROOT` at import and then importing `app` only works if that file is the
first to import `app`. Import order must never decide where a test writes.

**Live purges delete sibling tests' fixtures.** Any test calling
`purge_orphaned_caches(dry_run=False)` must own a dedicated cache root established in `setUp`,
not at import time. A directory planted by an unrelated test was destroyed by another test's
purge **while the whole suite stayed green**.

**A naive SPA catch-all steals API routes.** `/<path:path>` intercepts GETs on POST-only and
unknown API routes and returns 200 `index.html`. Werkzeug prioritises method-matching rules.
Use `SpaPathConverter` with negative lookahead — see `AGENTS.md` for the exact regex.

**Frame accounting is the only trustworthy content measure.** Never write ENDLIST from a
duration ratio; never call `source_video_duration(path, fallback=<anything but None>)`; never
walk segment indices densely from 0. The `AGENTS.md` HLS section documents each of these with
the measurement that proves it.

**Verification must be done by a model that did not write the artefact.** This is a project rule,
not a suggestion. Route implementation and review to different models/harnesses.

**Measure UI in a browser; do not reason about it.** Twice in this project's recent history, a
change verified by reasoning shipped broken — an account menu that closed on hover, and a page
that "rendered fine" while 404ing on every title without artwork. Assert
`getBoundingClientRect()`, check `document.documentElement.scrollWidth === window.innerWidth`,
and read `console`.

**A green subset is not evidence.** The auth regression in §4.1 survived because the one test
file that would have caught it was never run in isolation. Run the file you changed.

---

## 7. How to verify a change

```powershell
# Frontend
cd web; npm run typecheck; npx.cmd vitest run; npm run build

# Backend
.\venv\Scripts\python.exe -m py_compile app\__init__.py
.\venv\Scripts\python.exe -m pytest tests\

# The shipped Android app's contract
python scripts\probe_android_api.py
```

For **UI** work, render against the live server and measure (§6). A clean DOM is not evidence
the data arrived; a page can look perfect while logging a 404.

For **isolation** claims, snapshot the library file list, production `movies` rows and
`cache/hls` directory hashes before and after — a green suite is exactly what hid the purge bug.

---

## 8. Current state, honestly

| Suite | Result |
|---|---|
| `tsc -b` | clean |
| `oxlint` (changed files) | clean |
| `vitest` | **91 passed** (11 files) |
| `pytest tests/` | **902 passed, 2 failed, 28 skipped** |
| `scripts/probe_android_api.py` | **18/18 per contract** |

**The 2 Python failures:**

1. `test_auth_foundation.py::TestSecretKey::test_startup_errors_when_on_without_secret` —
   pre-existing and documented. Unrelated to the migration.
2. `test_selenium_seek_playback.py::test_seek_preview_and_playback_advancement` — **the last
   unmigrated casualty**. Not merely "needs a browser": the log shows it loading `/`, getting
   the SPA shell, then failing `NoSuchElementException` on removed markup. It needs the same
   porting the other 36 received, and was missed because a Selenium test reads as
   environmental rather than as a contract failure. **This is the one outstanding piece of the
   test migration.**

### Known rough edges

- **`web/src/features/manage/ManagePage.tsx` is ~45 KB in a single component.** It works and
  is tested, but it is the one file in `web/src` well past the size where editing is safe.
  Split it before adding to it. `MovieDetailsPage.tsx` was modularised for exactly this reason.
- **`ManagePage.tsx` bypasses the typed API client**, calling bare `fetch()` directly
  (`/api/movies`, `/api/storage/settings`, `/api/storage/audit`, `/api/admin/verify`,
  `/api/storage/purge-orphans`, `/api/scan`, and the delete call — roughly lines 116–301).
  That means **none of those requests carry the deadline** described in §4.4. The risk is lower
  than it sounds — these are user-initiated actions, not background loads, so a hang leaves a
  spinner rather than an empty page — but the two most destructive routes in the application
  (media delete, cache purge) are among them. Routing them through `lib/api/client.ts` is the
  obvious follow-up; it was deliberately **not** done here, because a late refactor of an
  unfamiliar 45 KB component controlling media deletion is a worse risk than the gap it closes.
- **`docs/openapi.yaml` has drifted from the real API.** The generated `TechnicalSpecs` type
  declares 7 of the 10 keys the server actually sends, and spells one `filesize` against the
  real `file_size`. `web/src/lib/api/spec-drift.ts` records the differences; the spec itself
  has deliberately not been hand-edited, because the generated types derive from it.
- **`docs/PROJECT_STATUS.md` is 152 KB** and has accumulated a few double-mangled em-dashes
  from earlier tooling. Anchor edits on dash-free substrings and verify after writing.
- **PowerShell has no heredocs and rejects `&&`.** Use script files or `;`. Write multi-line
  content to a temp file, then read it back to confirm the tool did not mangle it.

---

## 9. Ranked next steps

1. **Port `test_selenium_seek_playback.py`** — the last migration casualty. Small, bounded, and
   it closes the test migration for good.
2. **Restart the service and set an Admin PIN.** The PIN channel is closed until an admin sets
   one; that is correct, but it should be a decision rather than an accident.
3. **Write down a backup and a restore drill.** No documented backup, no restore drill, no
   rollback window exists — for a machine holding a film library and a multi-day transcode
   pipeline. This is the largest unmitigated risk in the project.
4. **Decide on authentication before any wider sharing** (§5).
5. **Verify P3 or mark it unverified.** The PostgreSQL work exists but has never been run under
   authorization; treat it as untested code, not as progress.

---

## 10. Environment & operations

- **Windows 11**, Python 3.14.3 in `venv\`, Node 11, Flutter.
- Services: `MediaServer` (Waitress via NSSM) and `Cloudflared`, both automatic, both
  crash-restarting, 10 MB log rotation. Restart via `scripts\restart_service.bat` (elevated).
- **Storage is tiered.** `E:` = application, SQLite, HLS cache, previews (fast SSD).
  `D:` = cold media, upload staging, archive, deleted staging (high capacity). `C:` unused.
  All media/cache/subtitle paths must resolve across `config.get_media_roots()`.
- Secrets live in `.env` — never commit it.
- **Observatory vault** (project memory):
  `C:\Users\anis7\Documents\Obsidian Vault\Media Server\` (`OBSIDIAN_VAULT_PATH`).
  Read *Memory Index* and *Gotchas & Pitfalls* before non-trivial work; append dated entries to
  *Decisions Log* / *Verification Log* afterwards. **Append only — never rewrite another
  agent's entry.**

---

## 11. Reference

| Path | What |
|---|---|
| `AGENTS.md` | **Authoritative invariants.** Read first, every session. |
| `docs/PROJECT_STATUS.md` | Dated work log, newest first |
| `docs/MIGRATION_STATUS.md` | Phase-by-phase migration state |
| `docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md` | The measurements behind the transcoder |
| `docs/FLUTTER_CLIENT_STATUS.md` | Flutter client state and its test hazards |
| `docs/AUTHENTICATION_PLAN.md` | Auth design |
| `docs/openapi.yaml` | API spec (has known drift — see below) |
| `scripts/probe_android_api.py` | Executable Android-client guardrail |
| `scripts/hls_restore_endlist.py` | Frame-counted ENDLIST sealing (the sanctioned tool) |
| `web/src/main.tsx` | Route map |
| `web/src/lib/api/spec-drift.ts` | Where the real API differs from `openapi.yaml` |
| `app/routes/api.py` | Admin authorisation + most API surface |
| `app/services/transcode_service.py` | Transcoding, HLS cache, ENDLIST logic |
| `flutter_client/` | Android / Fire TV app |
| `web/dist` | **The served artefact.** Untracked by design. |