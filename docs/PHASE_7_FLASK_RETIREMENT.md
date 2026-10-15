# Phase A — Flutter Client Contract Baseline & Flask Retirement Inventory

**Date:** 2026-10-16
**Branch:** `feat/rust-transcode-worker`
**Status:** Phase A complete (read-only inventory + guardrail repair)
**Related:** `AGENTS.md` §0, `docs/PHASE_6_RUST_WORKER_PLAN.md`

---

## 1. The three findings that changed the plan

### 1.1 The guardrail had never tested Rust

`scripts/probe_android_api.py` hardcoded `BASE = "http://127.0.0.1:8000"`.
Every "18/18 per contract" recorded in the docs therefore validated **Flask**,
not the migration target. On `:8001` eight of those endpoints are proxied
straight back to `:8000`, so the probe could pass while measuring nothing at
all about Rust.

Fixed: the probe takes `--base` (default unchanged at `:8000`, so existing
invocations and any Task Scheduler entry keep working). Both origins now
report independently.

### 1.2 The probe silently omitted four shipped endpoints

Cross-checking the client source rather than trusting the probe's own
docstring found real coverage holes:

| Endpoint | Declared in | Was probed before |
|---|---|---|
| `POST /api/scan` | `ApiEndpoints.scan` | **no** |
| `POST /api/transcode/start` | `ApiEndpoints.transcodeStart` | **no** |
| `POST /api/cast/play` | `cast_repository.dart:54` | **no** |
| `POST /api/cast/control` | `cast_repository.dart:67` | **no** |

All four are shipped, user-reachable features (manual scan, manual transcode,
casting). The probe is now 22 endpoints, not 18.

### 1.3 The probe was not side-effect free

Adding the mutating endpoints exposed a hazard: `POST /api/transcode/start`
was originally probed against a real title. On an **untranscoded** film that
starts a real multi-GPU transcode of the user's library. The first run was a
no-op only because *2001 A Space Odyssey* happened to be already complete —
luck, not design, and the probe picks `movies[0]` arbitrarily.

Fixed: the mutating transcode call now targets the synthetic filename
`rust_probe_nonexistent_title.mkv`, which exercises the route contract without
touching content. Verified: 404 on both origins, nothing written to
`cache/hls`.

---

## 2. Measured status per Android client endpoint

> **Updated 2026-10-16, after Phase C1a + C1b.** All three artwork endpoints
> are now native and removed from the proxy map, leaving **9 proxied**
> (was 10) and **2 absent**:
>
> | Endpoint | Rust status now |
> |---|---|
> | `GET /poster/{*filename}` | **native** (C1a) |
> | `GET /tmdb-poster/{id}` | **native** (C1b) |
> | `GET /tmdb-backdrop/{id}` | **native** (C1b) |
> | `GET/POST /api/devices*` | proxied |
> | `GET /api/media-info/{f}` | proxied |
> | `GET/POST /api/cast/*` | proxied |
> | `POST /api/scan` | proxied |
> | `POST /api/transcode/start/{f}` | **absent** |
> | `GET /api/app/update`, `/api/app/download` | **absent** (not proxied either) |
>
> Verified live against Flask: byte-identical artwork, identical
> `Content-Length` and identical `Last-Modified` (so cached copies survive the
> port swap), traversal refused on both, download failure is 404 and never
> 500. TMDb download behaviour was measured before choosing the retry policy:
> 420 requests across 70 distinct assets at concurrency 12 over 6 rounds,
> 420/420 × 200, p95 0.66 s, no `Retry-After`, no throttling — so retries
> cover transient network errors, not rate limits.
>
> **Pre-existing limitation, inherited rather than introduced:** artwork cache
> files are keyed only on `tmdb_id`, so if TMDb re-encodes an image the cache
> never refreshes it. Observed live: two posters differed from their
> previously-cached copies at the same 500×750 dimensions, and a Python fetch
> of the identical URL returned exactly the bytes Rust wrote — i.e. upstream
> drift, not a defect. Flask behaves identically.

Probe run 2026-10-16, both origins, 22 endpoints.

| Endpoint | Flask :8000 | Rust :8001 | Rust status |
|---|---|---|---|
| `GET /api/movies` | 200 | 200 | native |
| `GET /api/movie/{f}` | 200 | 200 | native |
| `GET /api/system-status` | 200 | 200 | native |
| `GET /api/devices` | 200 | 200 | **proxied** |
| `POST /api/devices/heartbeat` | 200 | 200 | **proxied** |
| `POST /api/devices/client-hints` | 200 | 200 | **proxied** |
| `GET /api/transcode-status/{f}` | 200 | 200 | native |
| `GET /api/progress` | 200 | 200 | native |
| `GET /api/media-info/{f}` | 200 | 200 | **proxied** |
| `GET /api/cast/devices` | 200 | 200 | **proxied** |
| `GET /api/cast/status` | 400 (idle) | 400 (idle) | **proxied** |
| `POST /api/cast/play` | 400 | 400 | **proxied** |
| `POST /api/cast/control` | 400 | 400 | **proxied** |
| `POST /api/scan` | 403 | 403 | **proxied** |
| `POST /api/transcode/start/{f}` | 200 | **404** | **absent** |
| `GET /api/app/update` | 404 | 404 | **absent (not proxied either)** |
| `GET /api/app/download` | 404 | 404 | **absent (not proxied either)** |
| `GET /tmdb-poster/{id}` | 200 | 200 | **proxied** |
| `GET /media/{f}` | 200 | 200 | native |
| `GET /hls/{f}/playlist.m3u8` | 200 | 200 | native |
| `GET /subtitles/{f}` | 404 | 404 | native |
| `GET /poster/...` | 404 | 404 | **proxied** |

**10 of 22 are proxied, 2 are absent entirely.** Rust cannot serve `:8000`
yet.

### 2.1 A false green that must be closed

`POST /api/transcode/start` returns **404 on Rust** — the route does not
exist — yet the probe reports OK, because 404 is in the acceptable set for
mutating routes. `/api/app/*` is worse: the probe documents 404 as "route
present, nothing published for that channel", but on `:8001` it 404s because
**the route is missing**, so the in-app updater is simply absent and the probe
calls that a pass.

Before `:8001` becomes canonical these two must be tightened to distinguish
*route missing* from *route present, nothing published*. A guardrail that
cannot tell those apart stops being a guardrail.

---

## 3. Port ownership — the cutover constraint

The installed APK ships pointing at `http://127.0.0.1:8000`
(`settings_service.dart:32-34`, `player_poc_screen.dart:138`), overridable by
the user. Installed apps cannot be patched by us.

Therefore repointing the Cloudflare tunnel is **not** sufficient: it fixes new
sessions but leaves every already-installed app pointed at Flask. The plan
adopted is a **port-ownership swap** — Rust serves `:8000`, Flask moves to a
secondary port for rollback only. That keeps the client contract literally
unchanged and makes the probe validate whatever owns 8000 automatically.

This requires Phase C (full native parity) to complete **before** the swap;
B and C interleave rather than running strictly in sequence.

---

## 4. Flask surface still to be retired

From `app/routes/*.py` route decorators, beyond the client surface:

| Area | Routes | Client-visible |
|---|---|---|
| Transcoding | `/api/transcode/start`, `/api/transcodes`, `/api/media-readiness` | partially |
| Upload | `/api/upload`, `/api/upload/chunk/{init,<id>,<id>/complete}` | no (web) |
| Admin | `/api/admin/{verify,status,pin}` | no |
| Media delete | `DELETE /api/media/{f}`, `/api/media/delete/{f}` | no |
| Storage | `/api/storage/{audit,settings,purge-orphans,archive}` | no |
| Auth | `/auth/*`, `/api/auth/{me,tokens,tokens/<id>,allowlist}` | web only |
| Devices admin | `/api/devices/rename`, `/api/devices/delete` | no |
| Subtitles upload | `/api/upload-subtitle/{f}` | no (native in Rust) |
| Scanner | `scanner_service` + `cache-maintenance-worker` background loops | no |
| Metadata refresh | `metadata-refresh-worker` 4-hourly | no |

Background workers are the non-obvious part: `auto_transcoder_loop`,
`cache-maintenance-worker` and `metadata-refresh-worker` have no HTTP surface
and will not appear in any route inventory. They must be ported explicitly or
they will die silently with Flask.

---

## 5. Phase A exit criteria — met

- [x] Probe accepts `--base`, default unchanged.
- [x] Probe run against both origins, 22/22 each.
- [x] Client surface cross-checked against `ApiEndpoints`, `cast_repository`,
      `player_media_resolver` — not the probe's own docstring.
- [x] Per-endpoint native/proxied/absent matrix recorded.
- [x] Probe side effects removed and verified.
- [x] Known false-green documented for later tightening.