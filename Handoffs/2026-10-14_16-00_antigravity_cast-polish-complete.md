# Handoff — Anis' Home Media Server

| | |
|---|---|
| **Date** | 2026-10-14 16:00 IST (10:30 UTC) |
| **Agent** | Antigravity |
| **Model** | advanced-agentic-coding |
| **Workspace** | `E:\MediaServer` |
| **Branch** | `feat/react-web-frontend` — **not pushed**, ahead of `origin/feat/react-web-frontend` |
| **Code state** | Phase 2 React Web Frontend fully delivered and verified against Flask backend: every Jinja template ported and removed; complete 6-phase video player parity with Cast remote control hardening (receiver volume anti-reset, 3-state mute toggle, WebVTT subtitle track delivery, in-cast subtitle selector, and clean receiver app quit via `cast.quit_app()`). |
| **Verified** | Frontend **149/149 passed** (22 suites); Backend Cast **56/56 passed**; Selenium E2E Cast Integration **100% PASS**; TypeScript `tsc -b` clean; Production bundle clean. |
| **Pushed** | **No** — pushing is reserved for the user |

> This header deliberately names the **code** commits rather than a single `HEAD`: a handoff
> that states its own hash is wrong the moment it is committed. The next handoff should cite
> this newest file in `Handoffs/`.

---

## Paste-ready prompt

Copy everything inside the block below to start the next session.

---

```
Continue work on Anis' Home Media Server at E:\MediaServer.

STATE
- Branch feat/react-web-frontend, ahead of origin (NOT pushed). Pushing is reserved for the user.
- Code state: Phase 2 React Web Frontend is completely delivered and verified against the Flask backend.
  - Phase 1: Core playback, Direct Play RFC 7233 byte-range streaming, HLS playlist fallback.
  - Phase 2: Subtitle Engine with CC merged pill, SubtitleSettingsModal, font/color/opacity/dual-axis alignment, and sidecar upload.
  - Phase 3: Extended controls (Aspect ratio cycle, PiP, playback speed, volume/mute, Nerd Stats HUD, Shortcuts modal).
  - Phase 4: Mobile gestures, Preloader overlay, Seek ripples (±10s), and double-tap zones.
  - Phase 5: 100% Transcode Completion Staging Gate (#transcodeGate) locking incomplete media, Dual AMD GPU telemetry, and Seekbar Hover Frame Previews in BOTH paused and playing states.
  - Phase 6: LAN Cast & DLNA Remote Playback integration (#castBtn, #castModal picker, #castBar second-screen HUD) with hardware volume anti-reset, 3-state mute toggle, full LAN WebVTT subtitle delivery, in-cast selector popover, and clean receiver app quit (cast.quit_app()).
- Verified at HEAD:
  - Frontend: 149/149 tests passed across 22 test files (npm test -- --run).
  - TypeScript: tsc -b passes with 0 errors.
  - Bundle: npm run build successfully built web/dist/ in 1.26s.
  - Backend: pytest tests/test_cast_api.py 56/56 passed.
  - E2E Selenium: tests/test_selenium_cast_integration.py passed 100%.
- Live host: MediaServer + Cloudflared NSSM services. Server on 127.0.0.1:8000,
  published at https://media.anisparvez.in via a Cloudflare tunnel.
- You WILL need to restart the service (scripts\restart_service.bat, ELEVATED) after any
  edit under app/ - Waitress caches bytecode and does not reload.
- You WILL need `npm run build` after any edit under web/src - web/dist is the served
  artefact and nothing else rebuilds it.

READ FIRST, IN THIS ORDER
- AGENTS.md            - authoritative invariants, non-negotiable.
- GEMINI.md            - process safety, cross-drive rules, Cast invariants.
- Handoffs\2026-10-14_16-00_antigravity_cast-polish-complete.md  - this document.
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

WARNINGS THAT WILL BITE YOU
1. Cast Disconnect MUST call cast.quit_app() and cast.disconnect(). Halting media alone
   leaves the default media receiver running as an empty black screen on the TV.
2. Cast status MUST query live receiver volume (volume_level * 100 and volume_muted),
   and remote UI sliders must enforce scrub isolation (scrubVolume) and progressive red track fills.
3. Cast Subtitles Require Full LAN URLs. Cast receivers cannot resolve relative paths (/subtitles/...).
   Tracks in media_info['tracks'] must use fully-qualified LAN origins with WebVTT mimetype.
4. NEVER bare `flutter test` - use scripts\run_flutter_tests.ps1. It purges media_kit's
   orphaned temp state; without it Windows PID recycling makes a new test process inherit
   a dead run's pointer file and hang every await.
5. Never resolve `conftest` by module name. tests/conftest.py and tests/integration/conftest.py
   share a basename, neither dir has __init__.py. Import conftest data as a fixture, never as a module.
6. The Admin PIN fails CLOSED and has no default. A hard-coded default existed and was removed.
   Never reintroduce a default, never accept the PIN from a query string.
7. _is_hls_truly_complete() is a PREDICATE and must never write. Sealing a cache is
   scripts\hls_restore_endlist.py, which counts frames first.
8. Frame accounting is the only trustworthy content measure. Never write ENDLIST from a
   duration ratio; never call source_video_duration(path, fallback=<anything but None>);
   never walk segment indices densely from 0.
9. A naive SPA catch-all steals API routes. app/__init__.py uses SpaPathConverter with a
   negative lookahead for exactly this reason - do not simplify it back to /<path:path>.
10. web/dist is the served artefact. Any change under web/src is invisible until npm run build runs.
11. Backend edits need an elevated service restart (scripts\restart_service.bat). Waitress caches bytecode.
12. PUSHING IS THE USER'S CALL. Do not run git push in background scripts.

VERIFY BEFORE YOU TRUST ANY OF IT
  .\venv\Scripts\python.exe -m pytest tests\test_cast_api.py -v
  cd web; npm test -- --run; npm run build
```

---

## 1. What this project is

`anis7t/media-server` — a self-hosted film library on one Windows 11 machine.

Three consumers share one Flask backend:

| Consumer | Surface | Notes |
|---|---|---|
| **Web UI** | React SPA in `web/` → `web/dist`, served by Flask | Single origin, so Google Sign-In cookie works |
| **Android / Fire TV** | Flutter in `flutter_client/` | **Shipped and working.** Requests **no HTML** — no WebView anywhere |
| **Cast / DLNA** | Samsung TVs, Chromecasts, Nest Hub | Byte-range + HLS, CORS-enabled for receivers |

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
.\venv\Scripts\python.exe -m pytest tests\test_cast_api.py -v

# Frontend (cd web)
npm run typecheck        # tsc -b
npm test -- --run        # 149 tests across 22 files
npm run build            # REQUIRED: web/dist is the served artifact

# Flutter (cd flutter_client)
.\scripts\run_flutter_tests.ps1    # NEVER bare `flutter test`

# End-to-End Browser Tests
.\venv\Scripts\python.exe tests/test_selenium_cast_integration.py
```

### ⚠️ `web/dist` is the served artefact

Flask serves `web/dist/index.html` and its hashed assets. **Any change under `web/src` is
invisible until `npm run build` runs.** Restarting the service does not rebuild it.

### ⚠️ Backend edits need an elevated service restart

Waitress caches Python bytecode in memory and does not auto-reload. After editing anything
under `app/`:

```cmd
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
| **P0** | Architecture audit | **Complete** | Evidence-based inventory in `docs/PHASE_0_ARCHITECTURE_AUDIT.md` |
| **P1** | OpenAPI spec + contract tests | **Complete** | `docs/openapi.yaml`, `tests/test_api_contracts.py` |
| **P2** | React web frontend | **Complete for the Flask backend** | Every Jinja page ported and removed; full 6-phase player parity + Cast Remote hardening |
| **P3.1** | PostgreSQL adapter | Partially complete *(reported)* | `app/db.py`: migrations, advisory locks, pool lifecycle |
| **P3.2–3.3** | PG integration tests, timestamp compat | Partially complete *(reported)* | |
| **P3.4–3.8** | Test isolation, write guards, cache hardening | Partially complete *(reported)* | |
| **P4** | Rust Axum API foundation | **Planned / Not started** | |
| **P5** | Rust media & streaming engine | **Planned / Not started** | |
| **P6** | Rust transcode worker | **Planned / Not started** | |
| **P7** | Production cutover & Flask deprecation | **Planned / Not started** | |

---

## 4. Current code state and verified invariants

1. **Phase 2 Completion**: Every web page (`/`, `/movie/*`, `/watch/*`, `/account`, `/manage`, `/devices`, `/manual`) is an SPA view built in React 19 + TypeScript + Vite.
2. **Video Player Parity**: All 6 phases delivered:
   - Direct play & HLS transcode streams with zero PTS drift.
   - Merged CC pill with dual-axis subtitle positioning, custom colors/opacity, and sidecar upload.
   - Extended controls (aspect ratio cycle, PiP, playback speed, Nerd Stats HUD, shortcuts cheatsheet).
   - Mobile gestures, preloader overlay, rewind/forward skip ripples, double-tap zones.
   - 100% transcode completion gate locking incomplete transcodes with dual GPU telemetry.
   - Seekbar hover frame previews in both paused and playing states.
   - LAN Cast and DLNA remote playback with hardware master volume tracking, 3-state mute toggle, WebVTT subtitle tracks with live in-cast selector, and clean receiver app quit (`cast.quit_app()`).
3. **Admin PIN Security**: Fails closed, header/body only, zero query string acceptance.
4. **Zero Lingering Tasks**: All Selenium and browser automation wrap lifecycles in `try ... finally: driver.quit()`.

---

## 5. Next steps for the incoming agent

1. **P3 PostgreSQL Demonstration & Verification**:
   - The P3 code (`app/db.py`) exists but has never been authorized or executed against a real PostgreSQL instance.
   - Documented backup and restore drill for the film library and SQLite database must be authored before any migration is attempted.
2. **Production concurrency tuning & remote streaming benchmarks**:
   - Benchmark Waitress worker/thread pool against remote stream latency and Cloudflare tunnel limits.
