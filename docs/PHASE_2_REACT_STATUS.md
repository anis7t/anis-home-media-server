# Phase 2 — React Web Frontend

**Branch:** `feat/react-web-frontend`
**Started:** 2026-10-12
**Scope of the first slice:** roadmap sequence items **1, 3, 5** — app shell and
generated typed client, home screen and media library grid, browser player with
persisted playback progress. Items 4, 6, 7, 8 and 9 remain for later slices.

The acceptance thresholds this slice is judged against (Gates A–G) are recorded in
`FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md` under *Phase 2 acceptance
thresholds*. They were agreed before implementation.

## Running it

```powershell
cd web
npm install
npm run dev          # http://localhost:5173, proxies /api /media /hls /poster /tmdb-* to :8000
npm run verify       # typecheck + lint + unit tests + coverage + production build
npm run test:e2e     # Playwright, against the dev server and the live Flask API
```

The dev server must reach the running service on `127.0.0.1:8000`. Override with
`MEDIA_SERVER_ORIGIN`.

## Status against the gates

| Gate | Result |
|---|---|
| A — Scope | Met. Library → details → player reachable. **No Flask template deleted.** |
| B — Contract conformance | Met for the slice. Typed client generated from `docs/openapi.yaml` (59 paths / 65 operations / 31 schemas). **Known spec defect below.** |
| C — Test floors | Met. 52 unit/component tests; 86.3% lines across `src/features` + `src/lib`; PlayerPage 80.26%, MovieDetailsPage 100%, lib 90.32%. One Playwright E2E covers library → detail → playback → progress persisted. |
| D — Static | Met. `tsc --noEmit` clean, zero `any` in `src/lib/api`, `vite build` succeeds. Two lint warnings remain and are intentional (caller-owned effect deps; state reset on filename change). |
| E — Perf budget | Met, with headroom. **87.70 kB gzip** initial JS against a 250 KB budget. `hls.js` (179 kB) is a separate lazy chunk fetched only for MKV/HEVC titles. |
| F — Playback correctness | Met. `/media` and `/hls` unchanged; `CORS_PATHS` in `app/routes/media.py` untouched. Direct play verified at `readyState 4`, `videoWidth 1920x864`. |
| G — Docs | This document, plus the roadmap thresholds and the Phase 2 row in `MIGRATION_STATUS.md`. |

## Three defects found while building this

All three were invisible to mocked unit tests and to the contract suite. They were
found by running the real app against the real server.

### 1. `docs/openapi.yaml` is wrong about the field the library grid depends on

`MovieSummaryItem` declares `poster_path?: string | null`. **The live
`GET /api/movies` response has no `poster_path` field at all.** It returns
`poster`, in a tagged form (`tmdb:<id>` or `local:<relpath>`), plus
`details_json` (a raw JSON **string**) and `last_metadata_refresh`, none of which
the spec declares.

Building poster URLs from the spec's field name yields a grid of empty images for
the entire library. The server's real rule is
`app/services/media_service.py:678-694`, which branches on the `tmdb:` prefix and
strips the 6-character `local:` prefix.

Handled by widening the generated types in `web/src/lib/api/spec-drift.ts`, which
documents the divergence. **`schema.ts` is left untouched and the spec has NOT
been corrected** — that is Phase 1 contract work and
`tests/test_api_contracts.py` asserts against the spec. Correcting it is a
decision, not a silent fix.

Note the scale of the underlying gap: `tests/test_api_contracts.py` has **15 test
definitions against 65 operations**. It does not cover the whole contract.

### 2. Progress was never written during ordinary playback

`PROGRESS_INTERVAL_MS = 5000` was compared against `video.currentTime`, which is
in **seconds**. The throttle therefore demanded an 83-minute advance before it
would save anything, so watch progress was silently never persisted for any
normal viewing session. Renamed to `PROGRESS_INTERVAL_SECONDS` so the unit cannot
be misread again.

Unit tests missed this because they stub `currentTime` and never run the real
interval against real media. It was found by watching the network in a browser
while a real file played.

### 3. Progress writes and reads were scoped differently

The resume read (`GET /api/progress`) sends `X-Device-Id` and resolves from
`device_watch_history`. The write (`POST /api/progress`) did **not** send the
header, so it landed only in the shared `progress` table — a row the
device-scoped read never looks at. A browser could save a position it could never
read back.

Both are now device-scoped. Verified by round-trip on a live device id.

## Not resolved by this slice

- **Authentication is absent and remains out of scope by decision.** `media.anisparvez.in`
  is public and unauthenticated. Phase 2 does not widen that exposure —
  `/api/*` is already reachable by anyone holding the URL — but it places a
  polished browser client in front of it. Tracked as an open security gap.
- **Flask page routes are untouched.** Roadmap:153 forbids removing them before
  the React counterparts are verified, and they have not been.
- **Production build is not yet served by Flask.** `web/dist` exists but nothing
  serves it; deployment is a later decision.