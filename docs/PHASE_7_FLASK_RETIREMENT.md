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

### Phase C3a — device registration and keepalive, native

| Endpoint | Rust status |
|---|---|
| `POST/GET /api/devices/heartbeat` | **native** |
| `POST /api/devices/client-hints` | **native** |
| `GET /api/devices` | proxied (C3b) |
| `POST /api/devices/rename`, `/api/devices/delete` | proxied (C3b) |

C3b is deferred, not forgotten: those three are gated by
`is_admin_authorized()`, which resolves through the Google session in
`/auth/*` — the last slice. Porting them before auth would mean porting the
admin gate first, which is a larger change than it looks.

**The device id is the load-bearing detail.** It is cookie → `X-Device-Id` →
`sha256("<ip>|<ua>")` first 16 hex chars prefixed `dev_`, and every
`devices` row is keyed on it. Any divergence — a different separator, a
different hash slice — silently fragments the fleet view into duplicate
devices, one per client per change, with no error anywhere. It is pinned by
a test against the Python formula rather than trusted.

**`ConnectInfo` is required, not cosmetic.** Flask classifies the connection
from `remote_addr`. Without the peer address every client is `127.0.0.1` and
`connection_type` reads "Localhost" for every real device. The router is now
served with `into_make_service_with_connect_info::<SocketAddr>()`.

In axum 0.8 `Option<ConnectInfo<_>>` **does not compile** — `Option<T>` now
requires `OptionalFromRequestParts`, which `ConnectInfo` does not implement.
It is taken directly and placed before the final extractor.

**`/proc/net/arp` is Linux-only.** `resolve_mac_address` reproduces the
Windows behaviour Flask already has ("LAN (ARP Pending)") rather than
implementing an ARP read that would change what the dashboard displays.

**GeoIP keeps Flask's 1.5 s budget** and stays best-effort: a lookup failure
degrades to the default label and never turns a keepalive into a failed
request.

Two defects were caught while building this slice:

1. **UA model extraction was greedy across `;` segments.** Python's regex
   `;\s*([^;]+?)\s+Build/` stops at the first `;` and yields `SM-A536E`; a
   naive "text between the first `; ` and the marker" yielded
   `Android 13; SM-A536E`, which matched no make rule and collapsed every
   Android device to "Generic Client".
2. **A pre-existing proxy test used `/api/devices/heartbeat` as its example
   of a proxied POST.** Once that endpoint went native the test kept passing
   while testing the wrong thing. It now uses `/api/devices/rename`, which
   is still proxied. This is the general hazard: a proxy test pins a path,
   and the path moving is silent.

### Phase C2 — `/api/media-info/{f}` native (verified)

| Check | Result |
|---|---|
| Status parity, 36 titles | 36/36 identical |
| Response key sets | 36/36 identical |
| Field-by-field values, 17 fields × 36 titles | identical except `rating` (see below) |
| Duration | **identical on all 36** |
| Latency, full sweep | Flask 9.7 s vs Rust 4.9 s cold (**2.0×**); ~34× once the probe cache is warm |

Three real defects were found by this sweep and fixed, none of which the
unit tests had caught:

1. **All metadata silently null.** `vote_average` is a PostgreSQL `real`
   (float4); decoding into `f64` failed the entire row and the swallowed
   error produced an all-null block — every title reported no title, genres,
   rating or runtime.
2. **Duration 57 ms long.** Matroska writes its video-end signal as a
   timestamp (`DURATION-eng` = `"01:40:06.042000000"`), and on a real MKV
   both `stream.duration` and `duration_ts` were absent, so that tag was the
   only source. Parsing it as a float failed silently and fell through to the
   container duration.
3. **Duration 4.25 s long on one title.** `source_video_duration` has three
   tiers and only two were ported. A library MKV has neither a stream
   duration nor any DURATION tag, so only a *packet scan* answers — jumping
   to the container midpoint and reading forward to the last video packet.
   Without it the container duration is reported, overstating the
   denominator by however much audio outlives the picture.

**Remaining difference is data, not code.** `rating` differs on 9 of 36
titles: SQLite stores `6.4` where PostgreSQL stores `6.389`. Verified
directly in both databases. This is pre-existing divergence between the two
stores, and PostgreSQL holds the more precise value; Flask simply reads the
other store.

> **Updated 2026-10-16, after Phase C1a + C1b + C2 + C3a.** All three
> artwork endpoints, `/api/media-info/{f}` and both device keepalive
> endpoints are now native and removed from the proxy map, leaving
> **7 proxied** (was 10) and **2 absent**:
>
> | Endpoint | Rust status now |
> |---|---|
> | `GET /poster/{*filename}` | **native** (C1a) |
> | `GET /tmdb-poster/{id}` | **native** (C1b) |
> | `GET /tmdb-backdrop/{id}` | **native** (C1b) |
> | `GET /api/media-info/{f}` | **native** (C2) |
> | `POST /api/devices/heartbeat` | **native** (C3a) |
> | `POST /api/devices/client-hints` | **native** (C3a) |
> | `GET /api/devices` | proxied (C3b, needs auth) |
> | `POST /api/devices/rename`, `/api/devices/delete` | proxied (C3b, needs auth) |
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
| `POST /api/devices/heartbeat` | 200 | 200 | **native** (C3a) |
| `POST /api/devices/client-hints` | 200 | 200 | **native** (C3a) |
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

**Proxied count has fallen 10 → 7 across C1a, C1b, C2 and C3a; 2 are absent
entirely.** Rust cannot serve `:8000` yet.

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