# Handoff — Anis' Home Media Server

| | |
|---|---|
| **Date** | 2026-10-14 21:20 IST (15:50 UTC) |
| **Agent** | Antigravity |
| **Model** | advanced-agentic-coding |
| **Workspace** | `E:\MediaServer` |
| **Branch** | `feat/react-web-frontend` — **not pushed**, ahead of `origin/feat/react-web-frontend` |
| **Code state** | Issues 1–7 in `docs/Current issues.md` resolved and verified; comprehensive structured User Manual & Operator Guide delivered in `docs/MANUAL.md` and in-app `ManualPage.tsx`. |
| **Verified** | Frontend **161/161 passed** (24 suites); Backend Admin/Devices/Manage **57 passed, 3 subtests passed**; Auth Tokens **45/45 passed**; TypeScript `tsc -b` clean; Production bundle clean (1.23s). |
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
- Code state:
  - Issues 1–7 from docs/Current issues.md systematically addressed and verified across 4 phases:
    - Phase 1: Manage page instant cache detection (probe_hls_cache_instant() < 100ms load) and skeleton loaders.
    - Phase 2: Auth architecture clarification (MEDIA_SERVER_AUTH unset open-door guest mode vs strict mode) & Account page Guest Mode polish.
    - Phase 3: Passwordless TV pairing token workflow (15-min codes minting 1-year device tokens), user-scoped pairing for non-admins, Admin PIN token minting support, and sliding Watch History Drawer on /account.
    - Phase 4: Admin-only gating for /manage with rich obsidian access-denied UI, client presence telemetry privacy scoping on /devices (hiding household IPs from non-admins with on-demand PIN unlock), and backend route hardening (POST /api/scan, POST /upload, POST /upload/chunk/init, GET /api/storage/audit).
  - Documentation Overhaul:
    - docs/MANUAL.md: Comprehensive 13-section offline master operator guide with architecture diagrams, dual-drive tiering matrix (E: SSD + D: Mass storage; C: strictly unused), TV remote D-pad navigation, casting, and Windows persistent services runbook.
    - web/src/features/manual/ManualPage.tsx: Redesigned with modern web guidance and rich obsidian elements (quick-jump navigation rail, shortcuts table, gesture grid, 10-foot TV remote focus cards, and pairing workflow cards).
- Verified at HEAD:
  - Frontend: 161/161 tests passed across 24 test files (npm test -- --run).
  - TypeScript: tsc -b passes with 0 errors.
  - Bundle: npm run build successfully built web/dist/ in 1.23s.
  - Backend Admin & Manage: pytest tests/test_admin_auth.py tests/test_devices.py tests/test_manage.py (57 passed, 3 subtests passed).
  - Backend Auth Tokens: pytest tests/test_auth_tokens.py (45/45 passed).
- Live host: MediaServer + Cloudflared NSSM services. Server on 127.0.0.1:8000,
  published at https://media.anisparvez.in via a Cloudflare tunnel.
- You WILL need to restart the service (scripts\restart_service.bat, ELEVATED) after any
  edit under app/ - Waitress caches bytecode and does not reload.
- You WILL need `npm run build` after any edit under web/src - web/dist is the served
  artefact and nothing else rebuilds it.

READ FIRST, IN THIS ORDER
- AGENTS.md            - authoritative invariants, non-negotiable.
- GEMINI.md            - process safety, cross-drive rules, Cast & modal invariants.
- Handoffs\2026-10-14_21-20_antigravity_issues-1-7-and-manual-complete.md  - this document.
- docs\Current issues.md            - complete resolution log for Issues 1–7.
- docs\MANUAL.md                    - master 13-section operator and user guide.
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
4. Modal Dialog Portaling & CSS Transform Isolation: All modal dialogs MUST be portaled to
   document.body via createPortal(..., document.body). Page animations using forwards must terminate
   on `to { opacity: 1; transform: none; }` to prevent trapping position: fixed containing blocks.
5. Destructive/Critical Modal Outside-Touch Immunity: Confirmation modals (such as #purgeModal)
   must NEVER dismiss on backdrop touch or click.
6. The Admin PIN fails CLOSED and has no default. A hard-coded default existed and was removed.
   Never reintroduce a default, never accept the PIN from a query string. Header (X-Admin-Pin) and JSON body only.
7. NEVER bare `flutter test` - use scripts\run_flutter_tests.ps1. It purges media_kit's
   orphaned temp state.
8. web/dist is the served artefact. Any change under web/src is invisible until npm run build runs.
9. Backend edits need an elevated service restart (scripts\restart_service.bat). Waitress caches bytecode.
10. PUSHING IS THE USER'S CALL. Do not run git push in background scripts.

VERIFY BEFORE YOU TRUST ANY OF IT
  .\venv\Scripts\python.exe -m pytest tests\test_admin_auth.py tests\test_devices.py tests\test_manage.py -v
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

---

## 2. Commands

```powershell
# Backend
.\venv\Scripts\python.exe -m py_compile app\config.py app\services\transcode_service.py
.\venv\Scripts\python.exe -m pytest tests\test_admin_auth.py tests\test_devices.py tests\test_manage.py -v

# Frontend (cd web)
npm run typecheck        # tsc -b
npm test -- --run        # 161 tests across 24 files
npm run build            # REQUIRED: web/dist is the served artifact

# Flutter (cd flutter_client)
.\scripts\run_flutter_tests.ps1    # NEVER bare `flutter test`
```

---

## 3. Completed Work in this Session

1. **Issue 1 Resolution:** Fast synchronous directory existence probing (`probe_hls_cache_instant()`) eliminating 5–20s Manage page freeze and false "On-Demand HLS" badges. Added animated skeleton loading shimmers.
2. **Issues 2 & 3 Resolution:** Auth architecture documentation (`MEDIA_SERVER_AUTH` open-door vs strict mode), Account page Guest Mode polish, and removal of unauthenticated sign-out button.
3. **Issues 4, 5 & 6 Resolution:** Passwordless 6-character TV pairing token engine (`POST /api/auth/pairing-token/mint` & `claim`) generating 1-year bearer tokens (`ms_device_token`), user-scoped pairing for non-admins, Admin PIN support for token minting, and sliding Watch History Drawer on `/account`.
4. **Issue 7 Resolution:** Admin-only gating for `/manage` with rich obsidian access-denied hero card and portaled PIN unlock modal; client presence privacy scoping on `GET /api/devices` (hiding household IPs from non-admin callers) with on-demand PIN unlock; route protection for `POST /api/scan`, `POST /upload`, `POST /upload/chunk/init`, and `GET /api/storage/audit`.
5. **Comprehensive User Manual & Operator Guide:** Complete rewrite and expansion of `docs/MANUAL.md` (13 structured sections covering architecture, dual-drive tiering, TV remote navigation, auth, casting, retention, and Windows services) and redesign of `web/src/features/manual/ManualPage.tsx` with quick-jump rail, shortcuts table, gestures, and TV remote cards.

---

## 4. Next steps for the incoming agent

1. **Production concurrency tuning & remote streaming benchmarks:**
   - Benchmark Waitress worker/thread pool against remote stream latency, Cloudflare tunnel limits, and concurrent client playback.
2. **P3 PostgreSQL Demonstration & Verification:**
   - Author a documented backup and restore drill for the film library and SQLite database prior to any schema migration.
