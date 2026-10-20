# Media Server Modernization — Migration Status & Handoff

> ## Current session handoff - 2026-10-20 (12:30 IST)
>
> **A MISSED MIGRATION BACKLOG ITEM: the web brand opening sequence was never ported.**
> - **What:** the 3-second intro overlay shipped in the Flask era as `templates/intro-overlay.html`,
>   included at the end of the library page. **Slice 7E.2 retired it on 2026-10-18** (`5a2af4f`) with
>   the other legacy templates, and **no React component was ever written to replace it** - no
>   `BrandIntro`/`IntroOverlay` component exists in `web/src` or in any branch's history. The web app
>   has had no intro since 2026-10-18.
> - **Why it was missed:** the Slice 7E.2 sign-off verified the *architecture* - *"the React SPA
>   serves all pages directly without dependency on server-side Jinja templates"* - and that passed.
>   Nobody diffed *capabilities*. Worse, `AGENTS.md` asserted the overlay *"is wired into the React
>   SPA in `web/src/components/BrandIntroOverlay.tsx`"*, and **that file has never existed** - so
>   every later reader had a reason to believe the feature was live.
> - **Not lost:** the Flutter client still has it (`flutter_client/lib/features/intro/`, with its own
>   copy of the portrait video and two test files); all 293 MB of assets are intact in
>   `docs/opening-sequence/`; the design and the three web invariants are intact. The port is
>   well-specified, not a redesign.
> - **Status: OPEN** - item 5 of the `AGENTS.md` work queue. Full record:
>   [`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md) section 0 and
>   [`docs/SLICE_7E_WALKTHROUGH.md`](SLICE_7E_WALKTHROUGH.md) section 6.
> - **Lesson recorded:** *a decommissioning sign-off must diff capabilities, not just mechanisms.*
>
> ## Previous handoff - 2026-10-20 (10:55 IST)
>
> **OTT QR Device Sign-In is DELIVERED, HARDENED & VERIFIED.**
> - **Feature**: OTT-style activation for camera-less devices (smart TVs, browsers, consoles) — six native Rust Axum endpoints under `/api/auth/qr/*` (`create`, `lookup`, `wait` [SSE], `status`, `confirm`, `finalize`) backed by a PostgreSQL `device_pair_sessions` table, a `<QrSignInPanel>` on `/account`, and a standalone `/remotelogin` page for the phone. The phone signs in and names the device; the TV signs itself in.
> - **P0 security fix — pair-code entropy collapse**: the 5-character code had **5 bits of entropy, not 25**. All five characters were derived from the low bits of one 64-bit LCG state word, so the code collapsed to 32 possible values. Measured live: 40 sessions produced 15 distinct codes. Since `POST /api/auth/qr/lookup` resolves a code to a live pairing session, any signed-in account could try all 32 and hijack another user's active TV pairing. Now drawn character-by-character from the OS CSPRNG. **Verified live: 200 sessions → 200 distinct codes.**
> - **P0 security fix — predictable tokens**: `generate_random_token()` hashed a clock-derived seed. It mints session tokens, device tokens, the OAuth `state`/`nonce`, the PKCE `verifier`, and the `qr_id` — the only key to the unauthenticated `/finalize` endpoint. Now 256 bits from the CSPRNG, failing closed.
> - **P0 security fix — plaintext secrets in the log**: the pair code and the full `qr_id` are no longer logged; only a 12-hex-character reference is.
> - **P0 fix — the frontend suite was broken**: jsdom implements no `EventSource`, and the error thrown from inside an effect is fatal for that subtree in React, so it tore down the whole account page and failed every assertion in its file (5 failures). `web/src/test/setup.ts` now stubs it. The "Sign in with Admin PIN" accessible name was restored.
> - **Test-database isolation**: the entire Rust integration suite was running against the **production** `media_server` database, because `AppConfig::from_env()` falls back to it when `MEDIA_SERVER_DATABASE_URL` is unset — and on this host it is. The suite now uses a dedicated `media_server_test` database via the new `rust/src/test_support.rs`. `ensure_schema()` was also creating only 7 of the 13 tables, so a fresh database was half-formed.
> - **Test idempotency**: `qr_device_auth_flow_test` passed once and then failed on *every* subsequent run with a unique-constraint violation, leaving a phantom user and session in the live catalog. It now purges at setup, has an explicit async teardown, uses `ON CONFLICT`, and asserts zero residue.
> - **Verification Status**: Rust test battery (**108 unit + 26/26 integration targets green, exit code 0**), React Vitest battery (**248/248 passed**, was 222 passed / 5 failed), TypeScript (**0 errors**), production build (**clean**), Android API probe (**22/22 OK**), live pair-code entropy (**200 → 200 distinct**), production database residue (**0**).
> - Master Walkthrough: [`docs/QR_SIGNIN_WALKTHROUGH.md`](QR_SIGNIN_WALKTHROUGH.md).
>
> ## Previous handoff — 2026-10-18 (13:50 IST)
>
> **Phase 10 (Native Rust Media Scanner Engine) is 100% COMPLETE & VERIFIED.**
> - **Objective**: Completely eliminate Python from production runtime by porting `scanner.py` to native Rust.
> - **Decisions**: Option 1A (Strict Reconciliation / Orphaned Pruning) and Option 2A (ffprobe Container Duration Fallback).
> - **Delivered Slices**:
>   - Slice 10.1: Filename & Release Parser (Regex Cleaning & Multi-Year Resolution) — `84aef59`
>   - Slice 10.2: TMDb Async Client & Data Models (429 Backoff & JSON Synthesizer) — `59b8721`
>   - Slice 10.3: Crawler, ffprobe Fallback (2A) & Delta Database Engine (1A) — `d21e371`
>   - Slice 10.4: ScanService In-Process Integration & REST API Wiring (`/api/scan`) — `55ad242`
>   - Slice 10.5: Decommission `scanner.py`, Release Compilation & Test Battery — `4793fdb`
> - **Test Battery**: 21/21 tests passing across all 5 scanner suites (`background_daemon_test`, `scan_test`, `scanner_engine_test`, `scanner_parser_test`, `scanner_tmdb_test`).
> - Master Plan: [`docs/PHASE_10_NATIVE_RUST_SCANNER_PLAN.md`](PHASE_10_NATIVE_RUST_SCANNER_PLAN.md).
> - Master Walkthrough: [`docs/PHASE_10_WALKTHROUGH.md`](PHASE_10_WALKTHROUGH.md).
>
> ### Previous handoff — 2026-10-18 (03:15 IST)
>
> **Phase 7 Slice 7E & Full Modernization is 100% COMPLETE, VERIFIED & SIGNED OFF.**
> - **Slice 7E.1 (Scripts Audit & Tooling Modernization)**: Decommissioned 30 obsolete scripts, updated `service_status.ps1` (`9e75ee2`).
> - **Slice 7E.2 (Legacy Templates & Static Retirement)**: Retired 9 Jinja HTML templates (7,747 lines) and `static/` asset tree (`5a2af4f`).
> - **Slice 7E.3 (Legacy Python Backend Decommissioning)**: Decoupled `scanner.py` into standalone utility; decommissioned entire `app/` directory tree (35 files, 15,355 lines) and WSGI launchers (`c5ee97d`).
> - **Slice 7E.4 (Test Suite Modernization & Requirements Pruning)**: Pruned `requirements.txt` (removed Flask, waitress, gunicorn, win32); decommissioned 52 obsolete Python test suites (19,706 lines) while preserving historical load benchmark records in `tests/load/` (`5d0fbb3`).
> - **Slice 7E.5 (Architectural Documentation & Final Sign-Off)**: Modernized `AGENTS.md`, `README.md`, `PROJECT_STATUS.md`, and master handoffs.
> - **All 10 Phases Complete**: P0 (Architecture Audit), P1 (OpenAPI 3.1 & Contracts), P2 (React Web Frontend), P3 (PostgreSQL Migration), P4 (Rust API Foundation), P5 (Media & Streaming Engine), P2R (SPA Integration), P6 (Multi-GPU Transcode Cutover), P8 (fMP4 Quality Ladder), P9 (Pre-Transcode & Capabilities Probe), and P7 (Production Cutover & Flask Retirement).
> - **Verification Status**: Rust test battery (**119/119 passed** across all 15 test suites), React Vitest battery (**212/212 passed**), TypeScript (**0 errors**), Android API probe (**22/22 OK**), Phase 8 contracts (**OK**).
> - Refer to master walkthrough: [`docs/SLICE_7E_WALKTHROUGH.md`](SLICE_7E_WALKTHROUGH.md).
>
> ### Previous handoff — 2026-10-18 (02:40 IST)
>
> **Phase 9 & Active Issues Slices A–D are 100% COMPLETE & VERIFIED.**
> - **Phase 9 (Capabilities Probe & Pre-Transcode Architecture)**: W3C Media Capabilities API probe, strict 100% transcode gating (`#EXT-X-ENDLIST` required, isolated `<video>`), Option 1C native resolution baseline, Option 2A layman warnings, autonomous transcode sweeper, and `/manage` operator tooling (`22feeaf`).
> - **Slice A (APK Distribution `/download`)**: Native Rust endpoints `GET /api/app/download` (RFC 7233 byte-range streaming) and `GET /api/app/version`; obsidian-glass `<DownloadPage>` at `/download`, `/app`, `/android` with SHA-256 integrity verification (`6ba1e3a`, `6cdc0ff`).
> - **Slice B (Google Sign-In 503 & Admin PIN Fallback)**: `oauth_configured` probe flag on `/api/auth/me`; smooth redirection to `/account?error=oauth_unconfigured`; constant-time `POST /api/auth/login-pin` with 30-day session token cookie; portaled `<AdminPinSignInModal>` (`e4a423b`).
> - **Slice C (Subtitle Delay Flicker Elimination)**: Idempotent `applySubStyles` guards stylesheet DOM injection; decoupled effects into CSS, cue layout, and timing offset; smooth `applyCueTiming` with zero layout thrash (`8af2022`).
> - **Slice D (Native 4K HEVC Direct Play Unlock)**: Dimension-aware `normalizeVideoCodecMime` targeting `hvc1.1.6.L150.90` (Level 5.0 Main 10); W3C `decodingInfo` query with real dimensions and `hvc1`/`hev1` fallback (`62d4984`).
> - **Developer Experience**: Configured VS Code SQLTools PostgreSQL connection (`d7c814d`).
> - **Verification Status**: Rust test battery (**119/119 passed** across all 15 test suites), React Vitest battery (**212/212 passed**), TypeScript (**0 errors**), Android API probe (**22/22 OK**).
> - **Clarification on Slices**: Active issues contained only Slices A–D (no Slice E; all resolved).
>
> Repository state: branch `feat/phase-9-pre-transcode-capabilities` clean.
> Refer to master handoff: [`Handoffs/2026-10-18_02-40_antigravity_slices-a-d-complete-and-slice-7e-plan.md`](../Handoffs/2026-10-18_02-40_antigravity_slices-a-d-complete-and-slice-7e-plan.md) and [`docs/SESSION_HANDOFF_PHASE_7_BACKLOGS.md`](SESSION_HANDOFF_PHASE_7_BACKLOGS.md).
>
> ### Previous handoff — 2026-10-17
>
> **Phase 8 (Fragmented MP4 Streaming, Dynamic Quality Ladder Engine, Client-Aware Direct Play, and Modernized UI/UX) is 100% COMPLETE & VERIFIED.**
> - **Tier 1 (Automated Tests)**: Rust Backend (**103 lib + 42 integration passed**), Web Frontend (**183/183 passed**, built in 793ms), Flutter Frontend (**110/110 passed**, 0 analysis issues).
> - **Tier 2 (Client Contract Probes)**: All **22/22 Android API endpoints passed** contract; Client-aware direct play verified (Web MKV requires transcode with dynamic ladder vs Android MKV zero-copy direct play); Quality status & start verified.
> - **Tier 3 (Live Real Hardware fMP4 Transcode)**: Dual-AMD GPU transcode verified end-to-end on live sample clip at 2.6x real-time speed in 16 seconds. Master manifest (`#EXT-X-VERSION:7`), `#EXT-X-MAP`, and segments verified with `ffprobe` (1280x720 H.264). Zero storage pollution cleanup verified.
> - **Tier 4 (Live Web SPA & Asset Delivery)**: SPA shell, JS/CSS bundles verified HTTP 200, zero legacy raw HLS strings in bundle.
>
> Repository state: branch `feat/rust-fmp4-quality-ladder` ready for commit and merge.
> Next Phase: **Phase 7** — Production port cutover (`:8000`), Flask/Waitress service retirement, and final modernization sign-off.
>
> ### Previous handoff — 2026-10-14
>
> **Read `Handoffs/2026-10-14_16-00_antigravity_cast-polish-complete.md` for that snapshot.**
>
> Verified against the repository at `72c89f1` on `feat/react-web-frontend` (22 commits ahead
> of origin, **not pushed**):
>
> | | 2026-10-12 notice said | 2026-10-14 reality |
> |---|---|---|
> | Phase 2 (React) | **began**, scoped to roadmap items 1, 3, 5 | **Complete against the Flask backend.** Every Jinja page ported; full 6-phase Video Player parity delivered with Cast Remote hardening; Modal dialogs portaled to `document.body` resolving CSS transform containing block traps; Manage page audit latency (~20s) tracked in backlog |
> | Legacy test migration | 36 Jinja HTML assertions still failing | **Resolved.** Re-pointed at SPA shell status and real API contracts. `test_seek_preview_and_playback_advancement` fully migrated and passing in headless Selenium E2E |
> | Auth | Out of Phase 2 scope; an open gap | **Delivered.** Google Sign-In live, profile resolves, QR pairing works, `@require_admin` guards the destructive routes |
> | SPA routing | not recorded | `SpaPathConverter` catch-all, so the frontend can no longer shadow API routes |
> | Security | not recorded | **Hard-coded default Admin PIN removed** — it had meant public unauthenticated access to library deletion. PIN now fails closed |
>
> **Resolved (2026-10-14):** **Backup, restore drill, and rollback window are DELIVERED & VERIFIED.**
> [`docs/BACKUP_AND_RESTORE.md`](BACKUP_AND_RESTORE.md) is the master runbook. Crash-safe online SQLite
> WAL backup engine (`app/services/backup_service.py`), automated CLI tools (`scripts/backup_database.py`,
> `scripts/restore_database.py`), Windows scheduled task wrapper (`scripts/backup_database.bat`), and 8/8
> passing pytest integration tests (`tests/test_backup_restore.py`). A live baseline backup was captured
> and verified on the host with an end-to-end dry-run recovery drill.
>
> **Still open for Phase 3:** Representative regression run of `app/db.py` against a live PostgreSQL
> instance, row reconciliation, and final database write-ownership cutover.
>
> **P3.1–P3.8 are still marked *(reported)* below and should stay that way** until executed
> under authorization. Treat them as untested code, not as progress.
>
> **Only one known pre-existing test failure**: `test_startup_errors_when_on_without_secret`
> (pre-existing auth config test). `test_seek_preview_and_playback_advancement` is **fully resolved and passing in headless Selenium E2E**.

> ## ⚠️ Reconciliation notice — 2026-10-12
>
> **This document below is a 2026-10-10 snapshot and is materially out of date.**
> Its blockers were subsequently resolved on `main`. Read this notice before the
> body text; where the two disagree, this notice wins.
>
> Verified against the repository on 2026-10-12:
>
> | Snapshot claim (2026-10-10) | Verified reality (2026-10-12) |
> |---|---|
> | Branch 2 commits ahead of origin, NOT pushed; 16 modified + 13 untracked | `main...feat/rust-react-postgres-migration` = **25 ahead / 0 behind**. Fully merged, zero divergence. The branch is a spent artifact. |
> | P3.3–3.8G tests **untracked, never executed** (`compile()`/`ast.parse()` only) | All 10 files are **tracked**, landed via `064a9b3` ("make the suite order-independent — 54 failures to zero"). Suite: **720 passed / 28 skipped**. |
> | Issue 1 (**Critical**) enumeration completeness — "blocks complete: Yes" | **Fixed.** `16592be` is an ancestor of `main`. |
> | Issue 8 — `CachePurgeSafetyTests` shared-root defect | **Fixed.** `d1772e3`. |
> | Issue 9 — retention-test correction uncommitted | **Fixed and committed.** |
> | Issue 10 — 38 historical failures; "no completion claim defensible" | **Superseded.** 54 failures → 0, now 720 passing. |
> | §2.3 item 1 — phase numbering diverges 0–9 vs 0–7, "needs a decision" | **Resolved.** The roadmap's **0–7 is canonical**; the 0–9 scheme is retired (recorded in the roadmap header). |
> | §2.3 item 4 — roadmap status line stale ("Proposed roadmap only") | **Cleared.** Roadmap now reads Active. |
>
> **Phase 3 (PostgreSQL Migration) is COMPLETE (2026-10-14):**
> Data transfer and recovery demonstrated via `scripts/migrate_sqlite_to_postgres.py` with
> 100% row-for-row parity (852/852 rows). Real PostgreSQL 18.4 integration tests pass (26/26).
> Application suites pass against PostgreSQL (15/15 API contracts, 33/33 devices, 20/20 admin auth,
> 8/8 movies, 71 adapter tests). Phase 3 exit gate is fully satisfied.
>
> **Phase 4 (Rust API Foundation) is COMPLETE (2026-10-14):**
> Modular Rust Axum/Tokio/SQLx crate delivered on branch `feat/rust-api-foundation` with PostgreSQL 18.4
> pool management, structured tracing, health endpoints, movies catalog, and system telemetry.
>
> **Phase 5 (Media Library, Playback, and Streaming) is COMPLETE (2026-10-15):**
> All 5 sub-phase slices delivered and verified on `feat/rust-api-foundation` with 47/47 passing tests:
> - **Phase 5A**: Watch progress and history API (`/api/progress` GET/POST) with PostgreSQL upserts.
> - **Phase 5B**: Safe multi-root path resolution and RFC 7233 byte-range streaming (`/media/{*path}`).
> - **Phase 5C**: 100% Native Subtitle Engine — embedded container track discovery (`ffprobe`) and extraction (`ffmpeg`) to WebVTT, OpenSubtitles 64-bit LE hash downloads with native gzip streaming decompression (`reqwest` + `flate2`), local sidecar parsing with dynamic time offset shifting (`?offset=`), and multipart uploads. Full test coverage (16/16 tests passing).
> - **Phase 5D**: Seek-hover frame previews engine, WebVTT storyboards, and multi-root thumbnail cache (`/api/seek-preview-meta`, `/seek-preview`, `/preview-vtt`).
> - **Phase 5E**: HLS manifest/segment delivery, RFC 8216 target duration healing, transcode MP4 cache serving, and concurrency benchmarking (510.86 Mbps aggregate throughput, 32.5 MB RAM footprint).
> - **Catalog Test Artifacts Purge & Isolation**: Purged all 11 phantom test movies from PostgreSQL and SQLite (leaving exactly 39 genuine library movies); hardened preview tests with automated teardown hooks preventing catalog pollution. All 61 Rust tests passing.
>
> **Phase 2 (React) began 2026-10-12** on `feat/react-web-frontend`, scoped to
> roadmap sequence items 1, 3 and 5. Acceptance thresholds are recorded in the
> roadmap under *Phase 2 acceptance thresholds*. 172 frontend component/unit tests pass.
>
> **Phase 2R (React + Rust Integration & Hybrid Hosting) is COMPLETE (2026-10-15):**
> Full static SPA hosting and reverse-proxy bridge delivered on `MediaServerRust` (port 8001):
> - **Phase 2R-A**: Vite dual-origin dev proxy configured for seamless frontend development.
> - **Phase 2R-B**: Native Axum static SPA embedding with SPA fallback routing to `index.html`.
> - **Phase 2R-C**: Streaming reverse-proxy bridge (`rust/src/routes/proxy.rs`) forwarding unmigrated endpoints (`/tmdb-poster/*`, `/poster/*`, `/api/devices/*`, `/auth/*`, `/api/cast/*`, `/api/storage/*`) to Flask port 8000 with 61/61 Rust integration tests passing.
> - **Phase 2R-D**: Live End-to-End browser verification validating clean catalog (39 titles), movie details, player direct streaming, active subtitle tracks, devices dashboard, storage management gate, and user manual.
> - **Production Service**: `MediaServerRust` deployed as persistent Windows Service with 1-click restart parity (`scripts/restart_rust_service.bat`).
>
> **Phase 8 (Fragmented MP4 Streaming & Dynamic Quality Ladder Engine) is COMPLETE (2026-10-17):**
> Full modern fMP4 pipeline, multi-tier scaling engine, and cross-platform frontend quality switching delivered on `feat/rust-fmp4-quality-ladder`:
> - **Slice 1 (1A, 1B, 1C)**: Fragmented MP4 (`.m4s`) packaging with `#EXT-X-MAP` initialization (`init.mp4`), AMF GPU scaling (`vpp_amf`) with strict no-upscaling and even-width invariants, and RFC 8216 multi-variant master playlists (`master.m3u8`).
> - **Slice 2 (2A, 2B)**: Client-aware direct play evaluation (zero-copy MKV direct play for Android/Fire TV ExoPlayer), `/api/media-info` dynamic quality ladder endpoint, and quality-specific interactive transcode scheduling (`POST /api/transcode/start/{path}?quality={tier}`).
> - **Slice 3**: React Web Player in-player quality selector modal (`QualitySelectorModal.tsx`), seamless in-flight position-preserving switching, on-demand transcode trigger, and Nerd Stats HUD telemetry (183/183 tests passing).
> - **Slice 4**: Flutter Mobile & Fire TV client integration (`QualityOption` domain model, `QualitySelectorSheet` with touch and 10-foot D-pad remote support, `PlayerScreen` seamless switching, and Stream Specifications telemetry).
> - **Slice 5**: UI/UX terminology modernization (retiring raw "HLS" in favor of "Adaptive Stream" and "Stream Ready" across Web and Flutter) and full multi-tier regression verification.
> - **Verification**: 28/28 Rust tests passed, 183/183 Web tests passed (`npm run verify`), 110/110 Flutter tests passed (`flutter test`, 0 lints), deployed and serving live on port 8001.

**Authoritative Roadmap:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md)
**Migration branch (now fully merged into `main`):** `feat/rust-react-postgres-migration`
**Baseline Commit (previous revision of this document):** `b007944`
**Last Updated:** October 12, 2026 (reconciliation notice added; body below is the October 10 snapshot)

> This revision consolidates the PostgreSQL adapter work (Phase 3.1–3.8G) that has
> accumulated in the working tree since the `b007944` baseline. Every claim below is
> labelled by evidence class — see §10. Nothing here asserts that any test has been
> executed unless the execution is recorded with its phase.

---

## 1. Executive summary

The migration is **partially complete and out of sequence**. Phases 0, 1 and a
substantial portion of Phase 3 have been delivered. Phase 2 (React web frontend) has
**not been started**, yet Phase 3 work proceeded — a deliberate-looking deviation that
the roadmap does not sanction. Phases 4–7 (Rust) have not been started at all.

What can be claimed:

- The PostgreSQL adapter, versioned migrations, advisory locking and pool lifecycle
  are **committed** at HEAD.
- Test isolation and write guards are **written and statically reviewed but never
  executed** under authorization in this phase history.
- Cache-destructive-path hardening is **written, statically reviewed, and partly
  runtime-verified only through a single disposable `verify` run**.

What cannot be claimed:

- **No runtime test confidence exists for any Phase 3.3–3.8G work.** Every new test
  module in the working tree is untracked and has only ever passed `compile()` and
  `ast.parse()`.
- **The Phase 3 exit gate is not met.** The roadmap requires demonstrated data
  transfer and recovery, representative regression tests against PostgreSQL, and
  unambiguous write ownership (roadmap §5, Phase 3). None of the three is satisfied.
- **Production cache recovery is not claimed, attempted, or known to be possible.**

---

## 2. Migration plan and source of truth

### 2.1 Authoritative documents and their roles

| Document | Role |
|---|---|
| `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md` | **The governing plan.** Goals, non-negotiable rules, target architecture, phase sequence, per-phase exit gates, testing gates, risk register, cutover/rollback strategy, definition of done. Status line still reads *"Proposed roadmap only."* |
| `docs/MIGRATION_STATUS.md` (this file) | Execution tracker and handoff for the branch above. |
| `docs/PHASE_0_ARCHITECTURE_AUDIT.md` | Phase 0 deliverable — route inventory, schema inventory, Flutter compatibility matrix, risk register. |
| `docs/PHASE_1_MIGRATION_STATUS.md` *(does not exist)* | Referenced in commit `9766edc` history but absent from `docs/`; Phase 1 status was folded into this document. |
| `docs/openapi.yaml` + `tests/test_api_contracts.py` | Phase 1 executable contract — the compatibility reference for later phases. |
| `docs/PROJECT_STATUS.md` | Operational status of the *running Flask application*; not a migration artifact. |
| `docs/REPOSITORY_ASSESSMENT_AND_ROADMAP.md` | Pre-migration assessment; superseded by the roadmap for planning purposes. |

### 2.2 Governing goals (roadmap §1–§2)

Migrate Flask → **Rust (Axum/Tokio/SQLx) + React/TypeScript + PostgreSQL**, keeping
FFmpeg as the processing engine and the Flutter/Fire TV client working. Ten
non-negotiable rules apply; four are directly implicated by current state:

| Rule | Current state |
|---|---|
| 2 — Preserve behavior before replacing implementation | Held. No playback/streaming/transcode behavior was altered. |
| 4 — Separate risky changes | **Partially violated.** Phase 3 database work and a cache-destructive-path change are in the same uncommitted body of work. |
| 6 — Keep `main` releasable | **At risk.** The branch is 2 commits ahead of `origin` and unpushed; 16 modified + 13 untracked files sit uncommitted on top. |
| 7 — No destructive cutover without evidence | **Violated in practice.** A production cache deletion occurred during Phase 3.8 diagnosis. No backup or restore evidence is documented anywhere. |

### 2.3 Conflicts and gaps in the documentation

1. **Phase numbering diverges.** The roadmap defines Phases 0–7. The previous revision
   of this document defined 0–9, splitting roadmap Phase 7 into "Live Events" (7),
   "Operations" (8) and "Deprecation" (9). Neither document references the other's
   numbering. **Unreconciled — needs a decision.**
2. **The previous status revision is materially stale.** It recorded baseline
   `b007944`, marked Phase 2 "PENDING AUTHORIZATION" and Phase 3 "Planned", and
   asserted *"Zero Production Changes: No production Flask code … modified."* That
   assertion is now **false**: nine files under `app/` are modified and uncommitted.
3. **No phase weights exist.** Neither document defines measurable completion
   criteria or weighting, so **a defensible numeric completion percentage is
   unavailable** (§7).
4. **Roadmap §3 status line is stale.** It still states implementation has not been
   authorized, which no longer matches the repository.
5. **Acceptance criteria are stated only as exit gates**, not as measurable
   thresholds (no coverage %, no performance budget, no reconciliation tolerance).

---

## 3. Progress matrix

Status key: **Complete** · **Partially complete** · **Blocked** · **Not started** · **Unverified**

| Workstream | Intended outcome | Implementation evidence | Validation evidence | Status | Remaining work |
|---|---|---|---|---|---|
| **P0 — Architecture audit** | Evidence-based inventory before code changes | `docs/PHASE_0_ARCHITECTURE_AUDIT.md` | Documented; reviewed | **Complete** | None known |
| **P1 — API contracts & contract tests** | OpenAPI 3.1 spec + executable contract tests | `docs/openapi.yaml`, `tests/test_api_contracts.py` (both committed at `b007944`) | Reported 15/15 contract tests and 98 regression tests passing at Phase 1 | **Complete** (reported) | Re-verify; `test_api_contracts.py` is implicated in a known ordering failure (§6, item 10) |
| **P2 — React web frontend** | Vite/React/TS app in `web/` against the existing Flask API | **Started 2026-10-12** on `feat/react-web-frontend`; every Jinja page now has a React equivalent (`/`, `/movie/*`, `/watch/*`, `/account`, `/manage`, `/devices`, `/manual`, plus legacy aliases), served by a `SpaPathConverter` catch-all that cannot shadow API routes. Delivered: typed client generated from `docs/openapi.yaml`, app shell + account menu, library grid with hero spotlight, details (cast rail, trailer dialog, spec cards), player with direct-play + HLS, devices, manage and manual pages, per-request deadlines with retry. **Polished 2026-10-14:** Portaled all modal dialogs to `document.body` via `createPortal`, fixed `.animate-fade-in` CSS transform containing block trap, and tracked Manage page audit load latency (~20s) in backlog. | **151 unit/component tests passing**; `tsc -b` and `oxlint` clean; retry path verified in a real browser. Python suite **902 passed / 2 failed**; Android guardrail 18/18 per contract. | **Complete for the current Flask backend** | Manage page loading shimmer & audit cache optimization in backlog. Two known failures (1 pre-existing SECRET_KEY, 1 unmigrated Selenium test). Remaining roadmap items 2, 4, 6–9 are not frontend-slice work — see §7 of the handoff. |
| **P3.1 — PostgreSQL adapter** | Dual SQLite/PostgreSQL backend, versioned migrations, advisory locking, pool lifecycle | `app/db.py`: `POSTGRES_MIGRATIONS`, dynamic `normalize_sql` `%` escape, `ON CONFLICT` translation, datetime interval arithmetic | **Verified (2026-10-14)**: 71 adapter tests pass, 15/15 API contract tests pass under PostgreSQL | **Complete** | None |
| **P3.2 — PostgreSQL integration tests** | Opt-in real-PG tests against an isolated schema | `tests/integration/{conftest,test_postgres_migrations,test_postgres_timestamps}.py` | **26/26 passed in 15.21s** against PostgreSQL 18.4 (`media_integration_test`) | **Complete** | None |
| **P3.3 — Timestamp compatibility & Migration** | Normalize SQLite string ↔ PG datetime at boundary; automated data migration | `app/utils/formatting.py`, `scripts/migrate_sqlite_to_postgres.py` | **25/25 timestamp tests pass**; `migrate_sqlite_to_postgres.py` verified 100% row-for-row parity (852/852 rows across 10 tables) | **Complete** | None |
| **P3.4–3.7 — Test isolation & write guards** | No test may write to a deployed path | `tests/conftest.py` (+374), `tests/test_app.py` (+59), `tests/_isolation_paths.py`, `tests/_write_guard.py`, `tests/test_write_guard.py`, `tests/test_isolation_guard.py` (all untracked) | Reported 45 guard tests passing; `git diff --check` exit 0 | **Partially complete** — never executed under authorization in this history | Authorized run; `CachePurgeSafetyTests` isolation defect (§6, item 8) |
| **P3.8 — Cache/destructive-path hardening** | `MEDIA_SERVER_CACHE_DIR`; centralized cache-root boundary; refusal reporting | `app/config.py` (+115): `CacheRootUnsafe`, `approved_cache_root` (:81), `require_within_cache_root` (:122). `transcode_service.py` (+116), `media_service.py` (+46), `subtitles_service.py` (+63), `api.py` (+5), `worker_service.py` (+10) | One disposable `verify` run exited 0 with `VERIFY OK` (Phase 3.8G8P) | **Partially complete** | Enumeration completeness; A8/A13/A14; C3–C6 |
| **P4 — Rust API foundation** | Modular Axum app with SQLx and PostgreSQL 18.4 connection pool | `rust/` crate, `scripts/cargo.bat`, `docs/PHASE_4_RUST_API_PLAN.md`, `docs/PHASE_4_RUST_API_WALKTHROUGH.md` | **Verified (2026-10-15)**: 4/4 integration contract tests passing against PostgreSQL 18.4 (`media_server`), 0 warnings on `cargo check`, release binary compiled | **Complete** | None (Phase 5 will add media streaming & transcode worker) |
| **P5 — Rust media/playback/streaming** | Library, range streaming, HLS in Rust | `rust/src/routes/{media,hls,transcode,subtitles,preview,progress}.rs`, `rust/src/services/{range,hls,subtitle,preview}_service.rs` | **Verified (2026-10-15/16)**: 61/61 integration tests passing; live `:8001` streaming at 510 Mbps peak; catalog reconciled to SQLite truth (36/36) | **Complete (5A-5E)** | Phase 6 transcoding worker remains |
| **Operational resilience** | Survive reboots and USB-volume (`E:`) dropouts | `C:\MediaServer\bin\nssm.exe`, `C:\postgres` binaries, `MediaServerPG` service (NetworkService), `MediaServerWatchdog` 5-min task (`scripts/service_watchdog.ps1`) | Live failover drill passed 2026-10-16 (stopped Rust, watchdog restarted it); all origins + public 200 | **Complete** | Boot without logon *and* without `E:` remains unhandled by design |
| **P6 — Rust transcoding worker** | Queue ownership + FFmpeg orchestration | None | None | **Not started** | Entire phase |
| **P7 — Cutover, hardening, Flask retirement** | Staged cutover, tested rollback | None | None | **Not started** | Entire phase; blocked by P2–P6 |
| **Deployment / operations** | Preserve NSSM + Cloudflare topology | Unmodified; `.gitignore` (uncommitted) already anticipates `target/`, `node_modules/`, `pgdata/`, `.pgpass` | None in this branch | **Not started** | Cutover evidence (roadmap §9) |
| **Rollback / data safety** | Backup + demonstrated restore + point-of-no-return | Online SQLite WAL backup engine, CLI suite, recovery drill & [`docs/BACKUP_AND_RESTORE.md`](BACKUP_AND_RESTORE.md) | 8/8 tests pass (`test_backup_restore.py`); live baseline captured & verified | **Complete** | Automated Task Scheduler trigger optional |
| **Acceptance testing** | Per-phase exit gates met | Only the two Phase 0/1 gates have artifacts | Not re-verified | **Blocked** | Depends on an authorized full-suite run |

---

## 4. Current repository state

Read-only inspection performed 2026-10-10.

```
Branch            : feat/rust-react-postgres-migration
HEAD              : 99e63ed2fe6bca4172e9f4f263855be7d2016938
HEAD subject      : feat(db): add PostgreSQL schema migrations and harden cleanup
Ahead of origin   : 2 commits  (99e63ed, 10b7295) — NOT pushed
Staged            : 0
Modified (tracked): 16
Untracked         : 13
git diff --check  : exit 0 (no whitespace errors)
```

### 4.1 Committed vs uncommitted

**Committed (2 commits ahead of `origin`, unpushed):**

| Commit | Subject |
|---|---|
| `9766edc` | docs: add Phase 0 architecture audit and Phase 1 migration status documentation |
| `b007944` | feat(api): add OpenAPI 3.1 specification and automated contract test suite (Phase 1) |
| `03a2ea4` | feat(db): implement SQLite/PostgreSQL database adapter (Stage 1) and capture workspace state |
| `10b7295` | feat(db): normalize queries to ON CONFLICT and harden connection lifecycle (Phase 2) |
| `99e63ed` | feat(db): add PostgreSQL schema migrations and harden cleanup |

**Modified and UNCOMMITTED (16 files, +1229/−117):**

| Area | Files |
|---|---|
| Application code (**9**) | `app/config.py`, `app/routes/api.py`, `app/utils/formatting.py`, `app/services/{device,media,subtitles,system,transcode,worker}_service.py` |
| Tests (3) | `tests/conftest.py`, `tests/test_app.py`, `tests/test_storage_retention.py` |
| Tooling / user-owned (4) | `.gitignore`, `.vscode/settings.json`, `opencode.json`, `docs/AGENT_EXTENSIONS.md` |

**Untracked (13):** `tests/_cache_test_support.py`, `tests/test_cache_safety_boundaries.py`,
`tests/_isolation_paths.py`, `tests/_write_guard.py`, `tests/test_write_guard.py`,
`tests/test_isolation_guard.py`, `tests/test_timestamp_compat.py`,
`tests/integration/{README.md,conftest.py,test_postgres_migrations.py,test_postgres_timestamps.py}`,
plus user-owned `.vscode/extensions.json` and the root `=` artifact.

> `tests/test_storage_retention.py` carries **+139/−41 uncommitted**. The committed
> version contains **zero** occurrences of `_dedicated_cache_root`; the working tree
> contains five. The dedicated-root correction described in §6 item 9 is therefore
> **entirely uncommitted**.

All user modifications, untracked files and the reported `D:\Flicks` Mayday artifacts
are preserved. Nothing has been staged, committed, pushed, reset, restored, cleaned or
branch-switched during this documentation task.

---

## 5. Phase history

Distinguishing **runtime-executed**, **statically validated**, and **reported-only**.

| Phase | Work | Evidence class | Notes |
|---|---|---|---|
| 3.1 | PostgreSQL adapter, migrations, advisory locking, identity columns, pool close safety | **Runtime-tested (reported)** + committed | 72 adapter tests (1 skipped), 23 API tests. Not re-run since. |
| 3.2 | Integration tests gated on `MEDIA_SERVER_TEST_POSTGRES_URL`, per-test `pgi_<hex>` schema, fail-closed DB-name validation | **Runtime-tested (reported)** | 26 tests vs PG 18.4. Dedicated test database, not `media_dev`. Untracked. |
| 3.3 | `parse_db_timestamp` / `format_db_timestamp`; device + media service updated | **Runtime-tested (reported)** | Focused runs positive; baseline suite still showed 38 failures. |
| 3.4–3.7 | Isolation roots, dotenv-override repair, upload-target leak fix, `isolation_guard`, write guard (13 patches) | **Runtime-tested (reported)**, then **statically validated** | 45 guard tests reported passing. Full suite **not** re-run after later hardening. |
| 3.8 | `MEDIA_SERVER_CACHE_DIR`; cache-root boundary centralized in `app/config.py`; guarded purge/cleanup paths; refusal reporting | **Runtime-tested (reported)** | Response to a production cache-deletion incident. |
| 3.8G8A–N | Disposable bootstrap gate hardened (env swap, nested teardown, guarded restoration, ownership bookkeeping) | **Compile/AST only** | Gate never executed during those phases. |
| 3.8G8P | **One** authorized `python -B gate.py verify` run | **Runtime-executed** | Exit 0, `[GATE] VERIFY OK`, 13/13 patches installed and released, environment restored, 10/10 app↔config snapshots agreed. Proves *containment*, not destructive-path behavior. |
| 3.8G8Q | Read-only test plan; coverage matrix; enumeration-completeness analysis | **Read-only analysis** | Delivered this plan; no files written. |
| 3.8G8R/T/U | Stage A (5 tests), Stage B (6 tests), Stage C (6 tests), Stage D (2 tests) | **Compile/AST + `git diff --check` only** | 19 test definitions total in `tests/test_cache_safety_boundaries.py`. **Never executed.** |

### 5.1 The production cache incident

During Phase 3.8 diagnosis, a standalone script ran outside pytest. The cache-root
override did not yet exist and the script never rebound the in-memory cache attribute,
so `get_cache_dir()` resolved to the deployed cache tree. Media enumeration was
incomplete but non-empty, so the audit could not distinguish it from a complete
library. The reported result was deletion of **53 production cache directories**.

Two lessons are recorded in code: the cache-root boundary (`app/config.py:81-142`) and
the enumeration-completeness check (`transcode_service.py:340-356`).

**This document makes no claim that the deleted data is recoverable, and no recovery
was attempted.** What is documented: the guard added afterwards would **not** have
prevented this incident, because the fault was the *media enumeration*, not the cache
path. That half is addressed by the missing-root check; the broader half is not (§6).

---

## 6. Open risks and blockers

Status vocabulary: **Confirmed (static)** · **Reported, not rechecked** · **Partially mitigated** · **Blocked** · **Unknown**

| ID | Issue | Source reference | Severity | Status | Next action | Blocks "complete"? |
|---|---|---|---|---|---|---|
| **1** | **Enumeration completeness.** If every configured root exists but the walk silently omits media — including basename dedup collapsing two distinct files (`media_service.py:64-67`) or a root skipped without a word (`:58-59`) — the audit reports `degraded=False` and classifies live cache directories as orphaned (`transcode_service.py:414`). | `media_service.py:58-59,64-67`; `transcode_service.py:346-356,414,465-472` | **Critical** | **Confirmed (static)**; sentinel test C-B7 documents it and asserts no fix | Production decision required: a completeness signal from `video_paths()` or an enumeration self-report. A coverage threshold must **not** be invented. | **Yes** |
| **2** | **A8 — per-file containment.** `cleanup_cache()` validates only the `transcodes` directory once, then unlinks globbed files individually. | `transcode_service.py:247` (dir check); `:256`, `:262`, `:270` (unlinks) | **Medium** | **Confirmed (static)**; test deliberately not written | Application decision: re-validate each file, or document the directory check as sufficient | No |
| **3** | **A13 — local poster containment.** A DB-derived `local:` poster path is joined onto `MEDIA_ROOT` and unlinked with **no** `_is_within_media_roots` check and a bare `except: pass` — unlike the adjacent media-file deletion at `:427` which *does* check. | `media_service.py:397-404` (vs `:427`) | **High** | **Confirmed (static)** | Add containment validation mirroring `:427` | No |
| **4** | **A14 — archive / delete-source containment.** Target paths are built from a relative media path and unlinked without a media-root or archive-root containment check. | `transcode_service.py:627-633` (archive), `:660-665` (delete_source) | **High** | **Confirmed (static)** | Add containment validation before `target_path.unlink()` | No |
| **5** | **C3 — subtitle refusal propagation.** Refusals are recorded locally and logged, but the function returns only the flat `purged` list, so a caller cannot distinguish a refusal from an absent file. | `subtitles_service.py:370-431` (return at `:431`) | **Medium** | **Confirmed (static)**; documented in the test module, not asserted away | Return a structured result or a refusal list alongside `purged` | No |
| **6** | **C4/C5 — media purge refusal propagation.** `purge_media()` returns `'success': True` unconditionally regardless of `refused_cache_deletes`; the delete route returns it verbatim with HTTP 200. | `media_service.py:455` (vs `:463`); `api.py:568-575` | **High** | **Confirmed (static)** | Derive `success` from `refused_cache_deletes`; review the HTTP status | No |
| **7** | **C6 — post-transcode status masking.** `apply_post_transcode_policy()` returns `status='cache_purged'` unconditionally, even when the inner purge recorded refusals. | `transcode_service.py:684-692` (refusals at `:2159`) | **Medium** | **Confirmed (static)** | Derive status from the inner result | No |
| **8** | **`CachePurgeSafetyTests` isolation defect.** `setUp` uses `get_cache_dir()`, which conftest re-points at the **shared session cache** before every test; two tests then perform **live purges** against it with a single-file mocked enumeration. Any other directory in that shared tree is classified orphaned and deleted. | `test_storage_retention.py:407-408`, live purges at `:460` and `:482`; shared cache imposed by `conftest.py:278-286,513` | **Medium** (intra-session interference; production cache is not reachable) | **Confirmed (static)** | Re-home onto a dedicated root per test (Stage G) | No |
| **9** | **Retention-test correction uncommitted and untested.** `test_audit_and_purge_orphaned_caches` was given a dedicated cache root and its post-purge assertions inverted, but the change is uncommitted (`+139/−41`) and has never been executed. | `test_storage_retention.py:59-91` (helpers), `:119-228` (test), `:203-208` (inverted assertions) | **Medium** | **Confirmed (static)**; **runtime-unverified** | Commit decision, then an authorized focused run | No |
| **10** | **Historical full-suite failures.** A baseline run showed 38 failures, including `test_audit_and_purge_orphaned_caches` and order-dependent `test_app.py` failures. Root causes were diagnosed for two of them (module import ordering in `test_api_contracts.py` vs `test_app.py`; contradictory assertions in the retention test). | Reported; root causes diagnosed in Phase 3.8 | **High** | **Reported, not rechecked** | An authorized full-suite run is required before any completion claim | **Yes** |

### 6.1 Additional risks from the roadmap register

| Risk | Relevance today |
|---|---|
| Data loss during DB conversion (**Critical**) | **No documented backup, restore drill, or rollback window exists.** Directly required by the Phase 3 exit gate. |
| Queue split-brain / duplicate FFmpeg work (**Critical**) | Not yet applicable — Rust worker is not started. |
| Auth/security mismatch (**Critical**) | The roadmap requires an explicit authz matrix. `api_delete_media` returning HTTP 200 for a partly-refused delete is a relevant precedent (item 6). |
| Rewrite scope grows too broad (High) | The Phase 3.8 cache-hardening effort is unrelated to the migration's stated purpose and consumed substantial effort on a single branch. |

---

## 7. Assessment — are we on the correct path?

### 7.1 Direct answer

**Partially.** The *technical* direction matches the roadmap; the *sequencing and
branch discipline* do not.

**What supports alignment:**

- The PostgreSQL adapter was built to the roadmap's Phase 3 task list: versioned
  migrations, advisory locking, an explicit `schema_migrations` table, and a
  dual-backend abstraction rather than a big-bang replacement.
- `schema_migrations` plus `pg_advisory_lock` is the correct idempotency primitive for
  the required "idempotent migration/transfer utility" (roadmap §5, Phase 3 task 5).
- Compatibility was preserved: no playback, streaming, transcoding or client-facing
  behavior was altered.
- The uncommitted `.gitignore` additions (`target/`, `node_modules/`, `pgdata/`,
  `.pgpass`) anticipate exactly the roadmap's Phase 2 and Phase 4 toolchains.
- The cache-root hardening is a genuine safety improvement, and its analysis is
  documented rather than asserted.

**Where it has deviated or exposed gaps:**

1. **Phase order was skipped.** The roadmap sequences Phase 2 (React) before Phase 3
   (PostgreSQL) and states Phase 3 "Depends on Phase 0 and an agreed data
   ownership/cutover strategy" — not on Phase 2. Proceeding to Phase 3 while Phase 2 is
   untouched is a real deviation. *It may have been an intentional reprioritization, but
   no document records that decision.*
2. **Rule 4 was violated in practice.** Database work and a destructive-path change
   share one uncommitted working tree.
3. **Rule 6 is at risk.** 2 unpushed commits and 29 uncommitted/untracked files.
4. **The Phase 3 exit gate is unmet on all three clauses**: no demonstrated transfer or
   recovery, no representative regression run against PostgreSQL, and no documented
   write-ownership decision for a Flask/Rust coexistence that does not yet exist.
5. **No numeric percentage is defensible.** Neither document defines phase weights or
   measurable acceptance thresholds. Qualitative bands follow instead.

| Dimension | Band | Basis |
|---|---|---|
| Implementation progress (roadmap phases) | **Early-middle** | 2 of 8 phases delivered; a third (Phase 3) substantially built but not gate-passed; Phase 2 skipped; Phases 4–7 untouched. |
| Test confidence | **Low** | The entire Phase 3.3–3.8G body of new tests is untracked and unexecuted. Last full-suite run showed 38 failures, unverified since. |
| Operational safety | **Degraded, recovering** | A production cache deletion occurred. Mitigations are written and partially runtime-verified. No backup/restore evidence exists. |
| Production readiness | **Not applicable** | PostgreSQL is not the canonical store; no cutover has been attempted or is close. |

### 7.2 Biggest blockers

1. **Enumeration completeness (issue 1).** Only a live-cache-misclassification bug that
   can delete real transcodes. It requires a production design decision, not a test.
2. **No backup, restore drill, or rollback window (roadmap §9, Phase 3 exit gate).**
   This blocks any cutover regardless of code quality.
3. **Zero runtime validation of ~1,229 uncommitted lines and 19 new test definitions.**
4. **Issue 10 (38 historical failures) unresolved** — no completion claim is defensible
   until an authorized full-suite run exists.

---

## 8. Recommended resumption sequence

Each step is small and independently reviewable. Static work and runtime work are kept
separate, and **every runtime step requires explicit authorization**.

| # | Step | Type | Gate before proceeding |
|---|---|---|---|
| 1 | **Freeze and document the working tree.** Decide, per modified file, whether it belongs on this branch. Split the Phase 3.8 cache-hardening work onto its own branch — it is not a migration deliverable and violates roadmap rule 4. | Static | User decision recorded in this document |
| 2 | **Resolve the documentation conflicts in §2.3** — phase numbering, stale roadmap status line, and the missing measurable acceptance criteria. | Static | Both documents agree on numbering |
| 3 | **Reconcile the four tracked-vs-untracked boundaries** for `tests/test_storage_retention.py`, `tests/conftest.py` and `tests/test_app.py`. | Static | — |
| 4 | **Apply the four confirmed application fixes** — A13, A14, C4/C5, C3, C6 (items 3–7). Each is small, source-local and independently reviewable. | Static | Per-fix review; no test may be weakened |
| 5 | **Decide A8** (item 2) — re-validate per file, or document the directory check as the accepted boundary. | Design | Explicit decision recorded |
| 6 | **Re-home `CachePurgeSafetyTests` onto a dedicated root** (item 8). | Static | — |
| 7 | **First authorized execution: Stage A–D boundary tests only.** Run `tests/test_cache_safety_boundaries.py` in isolation. This is the first point at which any Phase 3.8G code has ever executed. | **Runtime — authorization required** | Stop and report results before anything else |
| 8 | **Authorized focused runs:** `tests/test_write_guard.py`, `tests/test_isolation_guard.py`, `tests/test_timestamp_compat.py`, `tests/test_storage_retention.py`. | **Runtime — authorization required** | Each reports separately |
| 9 | **Authorized full-suite run** with the cache/DB/media isolation proof (snapshot library list, `movies` rows and cache directory list before and after). | **Runtime — authorization required** | Resolves item 10 |
| 10 | **Re-baseline the suite.** Record the true failure count; fix ordering issues before adding new failures. | **Runtime — authorization required** | — |
| 11 | **Decide Phase 2 vs Phase 3 resumption** and record the decision in the roadmap. | Design | Roadmap amended |
| 12 | **Only after steps 1–10:** PostgreSQL reconciliation, transfer and rollback documentation per roadmap §5 Phase 3 tasks 4–9. | **Runtime — authorization required** | Backup + restore drill demonstrated |

Steps 1–6 are static and can proceed without touching production. Steps 7–12 require
explicit authorization at each point.

---

## 9. Next-session handoff

**Safe starting point.** `E:\MediaServer`, branch `feat/rust-react-postgres-migration`,
HEAD `99e63ed`. Step 1 of §8 — freeze/split the working tree.

**What was last completed.** Phase 3.8G8U — Stage D added two refusal-propagation
tests to `tests/test_cache_safety_boundaries.py` (now 48,219 bytes, 19 test
definitions). `tests/_cache_test_support.py` is 7,665 bytes. Both validated with
`compile()`, `ast.parse()` and `git diff --check` only.

**What must not be repeated.**

- Do **not** re-run the disposable gate. Its one authorized `verify` run (Phase
  3.8G8P) succeeded; the gate lives outside the repository under the system temp
  directory and is not tracked.
- Do **not** re-derive the cache-root boundary or the guard design — both are written
  and source-referenced here.
- Do **not** "fix" the C-B7 sentinel. It exists to document issue 1 and must stay a
  sentinel until a real completeness signal exists.
- Do **not** weaken or delete any existing assertion to make a test pass.
- Do **not** clean the reported `D:\Flicks` Mayday artifacts or the root `=` file.

**Still awaiting authorization.** Stage E tests; Stage G retention-test correction;
any pytest execution; the full-suite run; any PostgreSQL connection; any application
startup.

**Safe read-only commands to resume with:**

```powershell
git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
git status --short
git diff --stat
git diff --check
git ls-files --others --exclude-standard
```

**Explicitly unsafe without authorization:** anything invoking `purge_orphaned_caches`,
`audit_orphaned_caches`, `cleanup_cache`, `purge_media`, `video_paths`, `init_db`, the
worker loops, the Flask app, pytest, or any connection to PostgreSQL.

---

## 10. Evidence and confidence legend

| Label | Meaning |
|---|---|
| **read-only verified** | Established by inspection during this documentation task. Cites a file:line. |
| **runtime-tested** | Actually executed, with the execution recorded against a phase. |
| **statically validated** | `compile()`, `ast.parse()`, `ast.walk` or `git diff --check` only — **code shape, never behaviour**. |
| **reported** | Supplied project history or a prior phase's stated result. Not re-verified here. |
| **not verified** | No evidence of any class exists. |
| **blocked** | Cannot proceed without a decision or an authorization. |

### Claims by class

**read-only verified (this task):** branch/HEAD/status (§4); absence of `web/`, `rust/`,
`Cargo.toml`, `package.json` and any tracked `.sql` file (§3); PostgreSQL surface
locations in `app/db.py`; all ten issue locations in §6; the dedicated-root correction
being uncommitted (§4.1); document inventory and the conflicts in §2.3.

**runtime-tested:** exactly one thing in this branch's recent history — the Phase
3.8G8P `verify` run (exit 0, `VERIFY OK`). Everything else marked runtime-tested in
§5 is **reported**.

**statically validated:** all of `tests/test_cache_safety_boundaries.py` and
`tests/_cache_test_support.py`; every Stage 3.8G gate-edit phase.

**reported:** the 72/23/26/45/98 test counts, the 38-failure baseline, the 53-directory
cache deletion, and all PostgreSQL integration results.

**not verified:** every runtime behaviour of the Phase 3.3–3.8G application changes;
the C-B7 sentinel's predictions; the A5 symlink case, which will likely skip on this
host; whether the `_isolation_paths` union still covers every `.env` key `app/config.py`
reads beyond line 127.

**blocked:** Phase 3 exit gate (no backup/restore/rollback evidence); Phase 7 cutover;
any completion claim (issue 10).

---

*No tests were executed, no application code was started, no database or PostgreSQL
connection was made, no cache or media operation was performed, and nothing was staged
or committed in producing this document.*