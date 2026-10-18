# Project Status, Completed Work, Bugs & Hosting Requirements

Last reviewed: 2026-10-05
Repository: `anis7t/media-server`
Working branch: `feat/rust-react-postgres-migration`

---

## Media Server Modernization (React + Rust + PostgreSQL)

Full handoff document: **[`docs/MIGRATION_STATUS.md`](MIGRATION_STATUS.md)**  
Authoritative roadmap: **[`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md)**  
Active branch: `feat/rust-react-postgres-migration`

| Phase | Title | Status |
|:---:|---|:---:|
| 0 | Architecture Audit | ✅ COMPLETE — [`docs/PHASE_0_ARCHITECTURE_AUDIT.md`](PHASE_0_ARCHITECTURE_AUDIT.md) |
| 1 | OpenAPI 3.1 Spec & Automated Contract Tests | ✅ COMPLETE — [`docs/openapi.yaml`](openapi.yaml), [`tests/test_api_contracts.py`](../tests/test_api_contracts.py) (`b007944`) |
| 2 | React Web Frontend | ✅ COMPLETE — Vite + React 19 + TS under web/; full 6-phase player parity (Direct/HLS, Subtitles, Controls/Telemetry, Gestures/Ripples, 100% Transcode Gate & Seek Previews, LAN Cast / DLNA) + 172 Vitest tests passing |
| 3 | PostgreSQL Migration | ✅ COMPLETE — Automated migration utility (`scripts/migrate_sqlite_to_postgres.py`) with 100% row parity (852/852 rows), dual psycopg 3 adapter with parameter tokenization & ON CONFLICT translation, 26/26 real-PG integration tests, all core suites verified |
| 4 | Rust API Foundation | ✅ COMPLETE — Modular Rust Axum/Tokio/SQLx crate (`rust/`) with PostgreSQL 18.4 connection pool, health endpoints, movies catalog, system telemetry, and structured tracing |
| 5 | Media Playback & Native Streaming Engine | ✅ COMPLETE — Watch progress upserts, RFC 7233 byte-range Direct Play, 100% native subtitles (embedded container extraction via FFprobe/FFmpeg, OpenSubtitles hash download & gzip decompression via reqwest/flate2, sidecars, and multipart uploads), seek hover frame previews, and dual-GPU transcode telemetry; 61/61 Rust tests passing |
| 2R | React SPA Direct Integration | ✅ COMPLETE — Direct React SPA hosting on Rust with client-side routing fallback and transparent static asset delivery |
| 6 | Multi-GPU Worker Cutover & Active Transcodes UI | ✅ COMPLETE — Autonomous dual-GPU chunked transcoding in Rust with AMD AMF VPP filters and live telemetry |
| 8 | fMP4 Adaptive Streaming & Quality Ladder | ✅ COMPLETE — Fragmented MP4 (`.m4s`) HLS pipeline with `#EXT-X-MAP`, dynamic quality ladder (4K–360p), client-aware direct play, and cross-platform quality selectors |
| 9 | Client Capability Probing & Pre-Transcoding Architecture | ✅ COMPLETE — W3C Media Capabilities API probe, strict 100% transcode gating, Option 1C native resolution baseline, Option 2A layman warnings, automated sweeper, `/manage` operator tooling |
| 7 | Unified Production Cutover & Modernization Completion | ✅ COMPLETE — Slices 7A–7E Delivered & Verified (Rust Axum port 8000 cutover, daemons, operational tooling, full Flask/Waitress decommissioning & final modernization sign-off) |
| 10 | Native Rust Media Scanner & Ingestion Engine | ✅ COMPLETE — 100% Native Rust Scanner Engine in Axum (Slices 10.1–10.5, Options 1A & 2A, 21/21 tests passed, scanner.py decommissioned); [`docs/PHASE_10_WALKTHROUGH.md`](PHASE_10_WALKTHROUGH.md) |

---

## Immediate Active Issues & Work Queue (Reported 2026-10-18) — ✅ ALL RESOLVED

All 4 reported issues were grouped into Slices A–D, implemented, thoroughly verified, and committed (Note: there was no Slice E; all issues are resolved):

1. **"Get the app" button does not work (`/download`)** — ✅ **RESOLVED (Slice A)**:
   - Built native Rust endpoints `GET /api/app/download` (RFC 7233 byte-range streaming) and `GET /api/app/version`.
   - Created obsidian-glass `<DownloadPage>` at `/download`, `/app`, `/android` with SHA-256 integrity verification.
   - Committed in `6ba1e3a`; Walkthrough in [`docs/SLICE_A_WALKTHROUGH.md`](SLICE_A_WALKTHROUGH.md).
2. **Google Sign-in returns 503 Service Unavailable** — ✅ **RESOLVED (Slice B)**:
   - Added `oauth_configured` probe flag to `/api/auth/me`; redirect unconfigured requests cleanly to `/account?error=oauth_unconfigured`.
   - Implemented `POST /api/auth/login-pin` with constant-time comparison against `settings.admin_pin` and 30-day session token cookie.
   - Built portaled `<AdminPinSignInModal>` with setup guidance.
   - Committed in `e4a423b`; Walkthrough in [`docs/SLICE_B_WALKTHROUGH.md`](SLICE_B_WALKTHROUGH.md).
3. **Browser playback control's subtitle delay (+ / -) causes subtitle flicker** — ✅ **RESOLVED (Slice C)**:
   - Idempotent `applySubStyles` prevents redundant `<style>` DOM writes in `document.head`.
   - Decoupled `useSubtitles` into 3 separate effects (visual CSS, cue layout, timing offset).
   - Non-destructive `applyCueTiming` shifts `c.startTime` and `c.endTime` dynamically with 0ms cue layout thrashing.
   - Committed in `8af2022`; Walkthrough in [`docs/SLICE_C_WALKTHROUGH.md`](SLICE_C_WALKTHROUGH.md).
4. **Utilize Chrome native 4K HEVC / H.265 support** — ✅ **RESOLVED (Slice D)**:
   - Made `normalizeVideoCodecMime` dimension-aware, targeting `hvc1.1.6.L150.90` (Level 5.0 Main 10) for 4K HEVC.
   - Query W3C `navigator.mediaCapabilities.decodingInfo()` with real resolution and dual-tag (`hvc1` / `hev1`) fallback.
   - Passed video dimensions from `PlayerPage.tsx`. Unlocks Direct Play for 4K HEVC MP4 streams on supported platforms.
   - Committed in `62d4984`; Walkthrough in [`docs/SLICE_D_WALKTHROUGH.md`](SLICE_D_WALKTHROUGH.md).

### Active Roadmap Backlog
- **Modernization 100% Complete**: All modernization phases (Phases 0–9, Slices 7A–7E) are 100% delivered, hardened, and signed off. Legacy Flask (`app/`), Jinja templates (`templates/`), legacy static files (`static/`), and legacy tests have been decommissioned. See [`docs/SLICE_7E_WALKTHROUGH.md`](SLICE_7E_WALKTHROUGH.md).

---

## Flutter Client Migration (active â€” read before touching `flutter_client/`)

Full handoff document: **[`docs/FLUTTER_CLIENT_STATUS.md`](FLUTTER_CLIENT_STATUS.md)**

| Phase | Title | Status |
|-------|-------|--------|
| 1 | Flutter Client Foundation | âœ… Committed (`5b0b1fa`, `eadb257`) on `feat/flutter-player-poc` |
| 2 | Video Player POC | âœ… COMPLETE â€” All 6 stages (2Aâ€“2E + 2F Acceptance Report) PASS on LAN & WAN (`f8e8c23`) |
| 3A | Production Player Architecture | âœ… COMPLETE â€” Committed on `feat/flutter-production-player` |
| 3B | Android-First Timeline & Live Seek Preview | âœ… COMPLETE â€” Committed (`2e95246`) |
| 3C | Audio & Subtitle Track Selectors, Speed & Controls Polish | âœ… COMPLETE â€” 58/58 tests passed, zero analyzer issues |
| 4.1 | Library Data Layer & API Endpoints | âœ… COMPLETE â€” API contracts frozen |
| 4.2 | Library UI, Movie Card Grid, Continue Watching Rail | âœ… COMPLETE â€” physical device verified |
| 4.3 | Library Search, Sort, Filter | âœ… COMPLETE â€” debounced search, 3 sort modes, genre filter |
| 4.4 | Movie Details Screen & Direct Playback Handshake | âœ… COMPLETE â€” details â†’ play â†’ back flow verified |
| 4.5 | Multi-Channel Distribution & In-App Update Architecture | âœ… COMPLETE â€” update subsystem operational |
| 4.6 | Persistent Bottom Navigation & Settings Integration | âœ… COMPLETE â€” 3-tab shell (Home, Library, Settings), device-verified; 143 passed / 10 skipped (live-server tests opt-in) |
| 4.7 | Fire TV & Android TV 10-Foot Experience (Universal APK) | âœ… COMPLETE â€” Single universal APK (`in.anisparvez.media_server_client`) for Mobile & TV. Runtime capability detection, collapsible obsidian side rail (`TvSideNavigationRail`), borderless fullscreen TV player, autofocus action triggers, D-pad remote navigation, physical Fire TV Stick 4K (`AFTMM`) & Vivo mobile verified |

---

## 0. Recent work

> **Session handoffs live in `Handoffs/`** (`YYYY-MM-DD_HH-MM_<agent>.md`, IST). The newest,
> `Handoffs/2026-10-14_16-00_antigravity_cast-polish-complete.md`, describes the tree at `72c89f1`
> and carries the paste-ready prompt, the P0-P7 migration phase table, the test coverage,
> and the traps. Read it first; this log remains the detailed record of *why* each change was made.
> Migration state: `docs/MIGRATION_STATUS.md`; phase gates: `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`.

### 2026-10-16 — Catalog Reconciliation & USB-Dropout Service Watchdog

**1. Outage & diagnosis.** `media.anisparvez.in` returned 502 with
`dial tcp 127.0.0.1:8000: refused` in `C:\Cloudflared\cloudflared.log`:
`MediaServer` (`:8000`), `MediaServerRust` (`:8001`) and PostgreSQL were
all Stopped. Structural cause: everything except Cloudflared lives on USB
`E:` (`nssm.exe`, PG binaries + `pgdata`); E: glitched mid-run (USB
paging error + volume re-enumeration in System log, PG crash-recovery
traces) and SCM never restarts Stopped services on volume return — NSSM
cannot self-heal because `nssm.exe` itself was on the missing volume.
All three restored (elevated restarts); public site 200.

**2. Catalog reconciliation (PG `media_server` vs SQLite `media.db`).**
Flask served 36 titles, Rust 39. Full disk audit: SQLite 36/36 valid
(truth); PG held 6 stale rows — 3 bare keys for files now under
`subdir/file` layout (28 Days, Hail Mary, Oak Street) fixed by `UPDATE
filename`, 1 bare-key duplicate (28 Weeks) deleted, 2 fully orphaned rows
(Odyssey, WALL-E) deleted plus 1 orphaned WALL-E progress row (user
approved full clean). One transaction, JSON backup of affected rows.
Result: **36/36 parity, 0 missing on disk**; `cargo test` re-run
**61/61 green**, zero post-suite artifacts. Full account:
[`docs/SERVICE_WATCHDOG.md`](SERVICE_WATCHDOG.md).

**3. Watchdog delivered, drill-passed, then removed.** A `MediaServerWatchdog`
scheduled task was built and proven (stopped Rust → next tick restarted it,
`:8001` 200), then **unregistered by user decision** once NSSM's own restart
covered the crash case, because its 5-minute interactive run flashed a
console window on the desktop. `scripts/service_watchdog.ps1` /
`install_watchdog.ps1` / `uninstall_watchdog.ps1` are retained so it can be
re-armed on demand. Three traps recorded in the walkthrough: repo `.ps1` files
must stay pure ASCII (PS 5.1 mangles UTF-8 dashes into parse errors);
repetition on AtLogOn triggers never fires (use Once+Repetition); and
`pg_ctl status` reports a healthy NetworkService cluster as stopped, so PG
liveness must be probed with a TCP connect to 127.0.0.1:5432.

**Follow-up, same session:** NSSM rehomed to `C:\MediaServer\bin` and
PostgreSQL binaries to `C:\postgres` (data stays `E:\pgdata`),
registered as `MediaServerPG` (NetworkService, Automatic, restart-x3
recovery). Catalog still 36/36 after the move; `:8000`/`:8001`/public
all 200.

### 2026-10-14 — Frontend Technical Debt Resolution: ManagePage Modularization & Typed API Client (Option C)

**1. Typed Library & Storage Management API Engine ([`web/src/lib/api/manage.ts`](../web/src/lib/api/manage.ts))**
- Eliminated all bare `fetch()` calls from `ManagePage.tsx`, routing all network traffic through the typed API client with request deadlines (`DEFAULT_TIMEOUT_MS = 20_000`, `MEDIA_PROBE_TIMEOUT_MS = 45_000`).
- Implemented strongly typed endpoints:
  - `fetchManageMovies()`: Fetches movie inventory with deadline and error mapping.
  - `fetchStorageSettings(adminPin)`: Reads post-transcode retention policies with `X-Admin-Pin`.
  - `fetchStorageAudit(adminPin)`: Evaluates storage pool allocation and HLS cache integrity.
  - `verifyAdminPin(pin)`: Verifies Admin PIN without triggering false-positive session locks.
  - `updateStoragePolicy(policy, adminPin)`: Updates retention policy.
  - `purgeOrphanedCaches(adminPin)`: Purges unreferenced transcode directories.
  - `triggerLibraryScan(adminPin)`: Triggers library ingestion and metadata synchronization.
  - `archiveMovieMedia(filename, adminPin)`: Offloads raw MKVs to cold storage (`D:\Flicks\.archive`).
  - `deleteMovieMedia(filename, adminPin)`: Performs permanent deletion and cache purging.
- Extended base `RequestOptions` in [`web/src/lib/api/client.ts`](../web/src/lib/api/client.ts) to support `DELETE` and `PUT` methods along with custom `headers`.
- Authored test suite in [`web/src/lib/api/manage.test.ts`](../web/src/lib/api/manage.test.ts) (11/11 tests passing).

**2. Modular Subcomponent Decomposition (`web/src/features/manage/components/`)**
- Decomposed monolithic `ManagePage.tsx` (1,284 lines → 430 lines, ~66% code reduction) into 7 single-responsibility, highly reusable presentation components:
  - `AdminAccessGate.tsx`: Ambient obsidian Access Denied shield, 4 capability overview cards, and PIN unlock action.
  - `AdminPinModal.tsx`: Portaled modal with auto-focus PIN input, live error alerts, and escape-key dismissal.
  - `StoragePoolHud.tsx`: Utilization progress bar with aggregate free/total space and drive-by-drive breakdown (`E:` SSD runtime, `D:` raw media).
  - `RetentionPolicyCard.tsx`: Interactive policy selection cards (*Keep Both*, *Move to Archive*, *Purge After Watch*).
  - `OrphanedCacheAudit.tsx`: Orphaned directory telemetry, reclaimable space calculator, and one-click cache purge button.
  - `InventoryToolbar.tsx`: Search input with clear button, category filter chips (All, HLS, Direct, Watched, Unwatched), and sort dropdown.
  - `InventoryList.tsx`: Responsive media cards with poster thumbnails, stream badges (*Cached HLS*, *Direct Stream*, *On-Demand HLS*), watch progress, and actions (Watch, Details, Archive, Delete).
  - `DeleteConfirmationModal.tsx`: Portaled destructive deletion confirmation modal with media details, wipe checklist, and inline PIN authorization.
- Validated with Vitest: all 172 tests passed across 25 test files (up from 161 tests). Production bundle compiled cleanly in 780ms.

### 2026-10-14 — Production Concurrency Tuning & Remote Streaming Benchmark (Waitress WSGI & Cloudflare Tunnel)

**1. Cross-Platform Concurrency Benchmark Engine ([`scripts/benchmark_streaming.py`](../scripts/benchmark_streaming.py))**
- Developed an automated benchmark suite tailored for Windows 11 host architecture and the production Waitress WSGI server (PID 17644) under NSSM.
- Evaluated 3 distinct workload profiles across concurrency levels 1, 2, 4, 8, 12, 16:
  - **Direct RFC 7233 Byte-Range Streaming:** Simulates full 1080p MP4/AAC playback via staggered 2 MB byte-range chunks across *2001: A Space Odyssey* (2.44 GB).
  - **HLS Segment Delivery:** Simulates HLS players polling playlists and streaming consecutive transport segments across *Ghost in the Cell* (4K) and *2001: A Space Odyssey* (1080p).
  - **Mixed Workload:** 75% video streaming + 25% interactive API queries (`/api/movies`, `/api/system/status`, `/api/devices`, `/api/admin/status`) measuring latency and thread starvation under load.
- Integrated Windows host hardware and process telemetry via `psutil`: tracks CPU utilization, RAM usage, Waitress RSS memory, Waitress OS thread count, and network throughput.
- Enforced descriptive Client `User-Agent` (`MediaServerClient/1.0`), preventing Cloudflare WAF bot-mitigation false positives (`403 Forbidden`).

**2. Local Origin Scaling & 448 Mbps Throughput Validation**
- Validated that the 16-thread Waitress WSGI server effortlessly scales on LAN/Local loopback (`http://127.0.0.1:8000`), achieving **447.88 Mbps** aggregate throughput (~56 MB/s) with 100% request success and zero dropped connections.
- Direct stream TTFB scaled smoothly from 57ms (2 clients) to 543ms (16 clients), with per-client bandwidth averaging ~30–32 Mbps at 16 concurrent streams—well above the 5–8 Mbps bitrate required for 1080p playback.
- Waitress RSS memory remained completely flat between **80.6 MB and 94.9 MB**, and OS thread count remained constant at 22–24 threads.

**3. Cloudflare Tunnel Characteristics & Upload Pipe Bottleneck Identification**
- Characterized the remote streaming capacity through the Cloudflare named tunnel (`https://media.anisparvez.in`):
  - Remote aggregate throughput capped at **18.43 Mbps** regardless of concurrency, directly matching the host ISP's home broadband WAN upload ceiling (~20 Mbps).
  - Direct stream TTFB increased from ~2.8s at 1 client to ~15.4s at 16 clients, identifying an optimal operational limit of **3–4 concurrent 1080p remote streams**.
  - HLS segment streaming exhibited lower and flatter TTFB (~1.2s–1.5s) over the tunnel than raw MP4 byte ranges, confirming HLS's advantage for remote mobile and WAN playback.
  - Mixed API traffic under full remote video saturation revealed head-of-line tunnel queuing (~15–19s latency), while local origin API requests remained instantaneous (29–115ms), proving the bottleneck is the WAN uplink pipe, not Waitress thread exhaustion.

**4. Comprehensive Master Benchmark Report ([`docs/STREAMING_BENCHMARK_REPORT.md`](STREAMING_BENCHMARK_REPORT.md))**
- Authored a publication-grade benchmark report comparing current Windows 11 Waitress results (+328% local throughput over Gunicorn) against the September 2026 Linux baseline, complete with full data matrices, operational capacity guidelines, and reproducibility commands.

### 2026-10-14 — Database Backup, Recovery & Disaster Runbook (Phase 3 Blocker Resolved)

**1. Crash-Safe Online SQLite WAL Backup Engine ([`app/services/backup_service.py`](../app/services/backup_service.py))**
- Implemented zero-lock online SQLite database backup using the native SQLite Online Backup API (`source_conn.backup(dest_conn, pages=100)`). Transfers data page-by-page without blocking concurrent HTTP readers or writers, incorporating all committed WAL frames into a defragmented single-file database.
- Created atomic companion cryptographic manifests (`media_backup_<timestamp>_<label>.json`) recording SHA-256 file hashes, byte size, schema migration versions, and exact row counts across all database tables (`movies`, `progress`, `devices`, `device_watch_history`, `settings`, `users`, `auth_tokens`, etc.).
- Integrated configurable retention rotation (`prune_backups()`, default: retain 7 newest) safely pruning older snapshots and matching manifests.

**2. Atomic Database Restoration & Pre-Restore Rollback Points**
- Engineered safe atomic database restoration (`restore_database()`) with mandatory pre-verification (`verify_backup()`) guarding against corrupt or truncated files.
- Automatically captures a pre-restore safety rollback point of the active database before overwriting.
- Implemented Windows SQLite WAL/SHM cleanup: unlinks stale `media.db-wal` and `media.db-shm` sidecars prior to atomic staging swap, eliminating database disk image corruption from mismatched WAL replay.
- Post-validates the restored database with `PRAGMA integrity_check` and ensures `PRAGMA journal_mode=WAL` is active.

**3. CLI Automation & Windows Scheduled Task Batch Script**
- Created CLI utilities [`scripts/backup_database.py`](../scripts/backup_database.py) and [`scripts/restore_database.py`](../scripts/restore_database.py) with options for target directories, labels, retention counts, JSON output, and interactive confirmation prompts.
- Created [`scripts/backup_database.bat`](../scripts/backup_database.bat) for one-click backups and Windows Task Scheduler automated daily execution.
- Added `BACKUP_DIR = Path(os.environ.get("MEDIA_SERVER_BACKUP_DIR", BASE_DIR / "backups")).resolve()` to [`app/config.py`](../app/config.py) and added `backups/` to [`.gitignore`](../.gitignore).

**4. Comprehensive Master Runbook & Verification Suite**
- Authored master operational guide in [`docs/BACKUP_AND_RESTORE.md`](BACKUP_AND_RESTORE.md) covering crash-safety architecture, CLI commands, Task Scheduler recipe, emergency disaster recovery, and Phase 3 rollback window ($\le 30$ seconds point of no return).
- Authored test suite [`tests/test_backup_restore.py`](../tests/test_backup_restore.py) passing 8/8 tests with 100% coverage.
- Captured live host baseline backup (`E:\MediaServer\backups\media_backup_20261014_160426_pre-migration-baseline.db`, 516,096 bytes, SHA-256 `f5287598106a...`, 852 rows) and successfully verified with an end-to-end recovery drill.

### 2026-10-14 — Issues 1–7 Resolution & Comprehensive User Manual Overhaul

**1. Manage Page Performance & Instant Cache Detection (Issue 1)**
- Implemented `probe_hls_cache_instant()` in `app/services/media_service.py` performing synchronous directory existence probing without invoking FFmpeg or directory walking.
- Hydrated `/manage` media inventory in `< 100ms`, displaying real-time accurate badges (*Cached HLS* vs *Direct Play* vs *On-Demand HLS*) immediately without 5–20s delay or false optimistic labels.
- Added animated skeleton loading shimmer placeholders for the Storage Pool HUD and audit cards.

**2. Auth Architecture Clarification & Guest Mode Polish (Issues 2 & 3)**
- Documented open-door Guest Mode vs enforced `MEDIA_SERVER_AUTH=1` security model.
- Transferred device pairing from `/devices` to `/account`, reserving `/devices` purely for client presence and network telemetry.
- Replaced confusing "Signed in as Unknown" with an informative obsidian **Guest Mode** card explaining hardware cookie identification (`ms_device_id`), and replaced the unauthenticated Sign Out button with a prominent **Sign in with Google** button.

**3. Device Token Pairing, Admin PIN Support & Watch History Drawer (Issues 4, 5, 6)**
- Added passwordless TV pairing workflow (`POST /api/auth/pairing-token/mint` and `POST /api/auth/pairing-token/claim`) in `app/routes/auth.py`. 15-minute 6-character codes mint 1-year cryptographically secure bearer tokens (`ms_device_token`) for Android TV / Fire TV without typing passwords.
- Added user-scoped interactive Watch History Drawer on `/account` with poster thumbnails, timestamps, watch percentages, resume points, and a **Clear All History** action.
- Permitted non-admin authenticated users (`role: 'viewer'`) to pair devices in their own scope.
- Added Admin PIN authorization support to token minting, eliminating 403 barriers for administrators.

**4. Admin-Only Gating, Fleet Privacy Scoping & Route Hardening (Issue 7)**
- Gated `/manage` storage pool settings and audits behind administrator authorization (`role: 'admin'` or verified Admin PIN). Unauthorized visitors are presented with a rich obsidian Access-Denied card with ambient radial lighting, glowing pulse shield, 4 capability overview cards, and a portaled Admin PIN unlock modal.
- Scoped `GET /api/devices` to the caller's current device only (`is_current == True`) when unauthorized as admin, concealing other household IP addresses and sessions. Added an amber privacy scoping notice and an **"Unlock Fleet Telemetry"** header button.
- Restricted `POST /api/devices/rename` and `POST /api/devices/delete` to the caller's own `device_id` unless authorized as admin.
- Hardened `POST /api/scan`, `POST /upload`, `POST /upload/chunk/init`, and `GET /api/storage/audit` to require admin authorization (`403 Forbidden` on non-admin).

**5. Comprehensive Structured Manual & In-App Guide Overhaul**
- Fully rewrote and structured [`docs/MANUAL.md`](MANUAL.md) into a comprehensive 13-section master operator guide covering dual-drive storage tiering (E: SSD + D: Mass storage; C: strictly unused), authentication & PIN security, TV remote 2-zone navigation, touch gestures, device pairing, dual-GPU chunked transcoding, casting, retention policies, and Windows persistent services.
- Overhauled [`web/src/features/manual/ManualPage.tsx`](../web/src/features/manual/ManualPage.tsx) with modern web guidance and rich obsidian UI elements: quick-jump category navigation rail, keyboard shortcuts table, gesture grid, 10-foot TV remote focus cards, and pairing workflow cards.
- Added test coverage in [`web/src/features/manual/ManualPage.test.tsx`](../web/src/features/manual/ManualPage.test.tsx).

### 2026-10-14 — React Modal Portaling, CSS Transform Isolation & Manage Loading Latency Tracking

**1. Modal Dialog Viewport Centering & CSS Transform Isolation (`ManagePage.tsx`, `CastModal.tsx`, `AppShell.tsx`, `index.css`)**
- *The Issue:* Confirmation and unlock dialogs in `/manage` (Delete & Purge Confirmation, Admin PIN Unlock) were rendered "way off in position... very down", protruding into the bottom edge of the viewport with contents cut off below the screen.
- *Root Cause:* Under W3C CSS Transforms Module Level 1, any non-`none` value for `transform` (including `translateY(0)` retained by `forwards` on `.animate-fade-in`) turns the container into the containing block for all `position: fixed` descendants. The modal backdrop (`fixed inset-0`) was bound to the multi-thousand-pixel height of `<ManagePage />` rather than the viewport, centering the modal thousands of pixels down the page.
- *The Fix:*
  - Portaled all dialogs directly to `document.body` via `createPortal(..., document.body)` in `ManagePage.tsx` (`deleteTarget` and `pinModalOpen`), `CastModal.tsx`, and `AppShell.tsx` (`privacyOpen`).
  - Updated `@keyframes fadeIn` in `web/src/index.css` to terminate on `to { opacity: 1; transform: none; }`, ensuring container animations do not retain containing block traps indefinitely.
  - Added `.animate-overlay-fade` and `.animate-scale-in` keyframes.
  - Added `overflow-y-auto` to the backdrop and `my-auto` to the modal card for responsive centering and safe vertical scrolling without clipping on compact screens.
  - Added an Escape key listener in `ManagePage.tsx` for accessible dismissal.
  - Added `testTimeout: 15000` to `vite.config.ts` to prevent worker timeouts during Windows test executions.

**2. Open Issue Tracked: Manage Page Loading Latency & Optimistic Transcode Status Desync (`docs/Current issues.md`)**
- *Reported Issue:* When loading `/manage`, the page takes ~20 seconds to fetch and process storage audit data with zero loading skeleton or indicator. During this window, media files initially display optimistically as "On-Demand HLS" even when already fully transcoded, before abruptly updating to "Transcoded" once the audit payload completes.
- *Backlog Action Item:* Add an intermediate loading shimmer/skeleton for the storage pool and media inventory cards, and preserve known transcode states during the audit fetch.

### 2026-10-14 — Cast Remote Control Hardening: Volume Anti-Reset, 3-State Mute, In-Cast Subtitles & Clean Disconnect

**1. Volume Slider Reset & Anti-Jump (`app/services/cast_service.py`, `web/src/features/playback/CastBar.tsx`)**
- `cast_status()` and `dlna_status()` now query real receiver hardware volume (`volume_level * 100` and `volume_muted` for Cast; `GetVolume` / `GetMute` for DLNA).
- Added `scrubVolume` state isolation in `CastBar` preventing status poll ticks from overwriting slider position during adjustments.
- Applied progressive bold red gradient fill (`#e50914`) to `#castVolume` matching the web player slider, with numeric `#castVolumePercent` indicator.

**2. Dynamic 3-State Mute Toggle (`#castMuteBtn`)**
- Integrated dynamic SVG mute button with 3 states: Muted ($0\%$), Low ($< 50\%$), and High ($\ge 50\%$).
- Toggling dispatches `action: 'mute'` across Google Cast (`cast.set_volume_muted`) and DLNA (`SetMute`).

**3. In-Cast Subtitle Track Delivery & Live Selector**
- Google Cast `cast_load()` now attaches sidecar subtitle tracks via `media_info['tracks']` with fully-qualified LAN WebVTT URLs and high-contrast styling (`textTrackStyle`).
- Added a `CC ⚙` button and obsidian glass popover (`#castSubMenu`) in the remote transport row for live subtitle switching (`action: 'subtitle'`) and turning subtitles Off.

**4. Clean Google Cast Receiver App Quit & Disconnect**
- Disconnecting from Google Cast now calls `cast.quit_app()` (`socket_client.receiver_controller.stop_app()`), `cast.disconnect()`, and cache eviction.
- The TV terminates the default media receiver cleanly and returns to its ambient/home screen, matching DLNA behavior.

### 2026-10-14 - Request deadlines and retry; two defects caught before commit

**Context.** Committing the previous session's uncommitted work surfaced two defects and one
real gap. All three are fixed here; the commit of the underlying work is separate.

**1. A hung request was indistinguishable from a slow one (the "stuck page").**

`web/src/lib/api/client.ts` `request()` had no deadline, and neither did `useAsync`. A fetch
that never settled therefore produced an **indefinite skeleton with no error and no recovery**
short of a full page reload - which is exactly how the details page presented.

The deadline is measured, not guessed. Against this server:

| Observation | Cost |
|---|---|
| Cold `/api/movie/{filename}`, unseen title | 2.5s |
| Cold control title, first request | 7.79s |
| Ten simultaneous cold details requests | 3.5s wall |
| One request during service restart | **>30s (timed out)** |

So `DEFAULT_TIMEOUT_MS = 20_000`, and `MEDIA_PROBE_TIMEOUT_MS = 45_000` for
`/api/movie/`, `/api/media-info/` and `/api/transcode-status/`, which probe the file
server-side and would otherwise fail the slowest titles *deterministically* rather than by
accident. `/api/movies` keeps the 20s default.

Implementation notes worth keeping:

- One `AbortController` covers both reasons to stop (caller cancellation and the deadline),
  wired **by hand** rather than with `AbortSignal.any()` so no polyfill is carried.
- `timedOut` is checked **before** rethrowing, so a deadline reports as
  `ApiTimeoutError` instead of the platform's opaque "The operation was aborted".
- A caller abort stays an `AbortError`. If it were reported as a timeout, every route
  change away from a slow page would flash a spurious "server took too long" on the way out.
- The timer is cleared in `finally`, so a response that already arrived is never
  retroactively converted into a timeout.

`useAsync` gained `reload()`, and `StateMessage` renders a **Try again** button. The
failure state is no longer terminal. Verified in a browser, not by inspection: the first
details request aborted, the alert and button appeared, the button was clicked, the request
re-issued, the alert cleared and the content rendered - with no page reload.
Covered by six new tests (hang, no-fire-after-resolve, caller override, socket actually
released, caller-abort-is-not-a-timeout, probe endpoints get the longer budget).

**2. Hard-coded default Admin PIN - removed (`app/routes/api.py`).**

The uncommitted admin work defaulted to `get_setting('admin_pin', '6361')`. On a host
reachable from the public internet through the Cloudflare tunnel that is equivalent to
publishing **permanent unauthenticated access** to everything behind `@require_admin`,
which includes *deleting the library*, purging caches, moving originals into the archive
and rewriting the retention policy. `6361` is four digits on a box with a known catalogue.

`get_setting('admin_pin', '')` now, via `_configured_admin_pin()`. Unset means **no PIN
channel at all**, leaving only a Google admin session to set the first one - which is also
what `api_admin_status.has_pin` already reported, so the two can no longer disagree.
Pinned by `test_no_configured_pin_means_no_pin_is_accepted`, which asserts both that
`/api/admin/verify` returns 401 *and* that the destructive route stays shut, because a
closed probe with an open door would pass the weaker test.

The PIN is also no longer accepted from `?pin=`. A secret in a query string lands in
Waitress access logs, Cloudflare's edge logs, browser history and `Referer` headers -
four more places to leak the one secret guarding media deletion. Header and JSON body only.

**3. ENDLIST written from label arithmetic - reverted (`app/services/transcode_service.py`).**

`_is_hls_truly_complete()` was appending `#EXT-X-ENDLIST` when
`cumulative / source_duration >= 0.98`. Three separate problems:

- **The measure is the one this project proved untrustworthy.** A cache read 100% by
  duration while missing 277.2s of frames across 101 chunks; a 99.88% "repair" masked that
  same loss. Label arithmetic is precisely what the frame-accounting work exists to replace.
- **It would seal exactly the caches the frame accounting exists to catch** - a cache
  refused ENDLIST for measured loss would get it back from a duration ratio.
- **It wrote from a predicate, in a 1Hz progress callback, unserialised and non-atomically**,
  against the project's `_PLAYLIST_WRITE_LOCK` + `write_text_atomic` rule. A torn playlist
  read is exactly what `_hls_resume_point` then freezes into both the playlist and its `.bak`.

Reverted; the function is a predicate again, with the reason recorded at the branch.
Sealing a complete cache remains `scripts/hls_restore_endlist.py`, which re-checks with
frame counting. The same commit keeps a genuine fix in that file: Matroska track tags are
locale-suffixed (`DURATION-eng`), so `tags.get('DURATION')` missed them and
`source_video_duration` fell through to a container duration.

**Standing at this commit.**

| Suite | Result |
|---|---|
| Frontend `tsc -b` | clean |
| Frontend `oxlint` (changed files) | clean |
| Frontend `vitest` | **91 passed** (11 files) |
| Python `pytest tests/` | **2 failed, 902 passed, 28 skipped** |
| Android guardrail `scripts/probe_android_api.py` | **18/18 per contract** |

Progress on the open decision from the previous entry: **38 failed -> 2**. The 36 legacy
Jinja HTML assertions were ported to assert SPA shell status and real API contracts.

**The two remaining Python failures, honestly:**

1. `test_startup_errors_when_on_without_secret` - pre-existing and documented, unrelated to
   the migration.
2. `test_seek_preview_and_playback_advancement` (`test_selenium_seek_playback.py`) - **the
   last unmigrated casualty**, and not merely "needs a browser". The captured log shows it
   loading `/`, receiving the SPA shell and then failing `NoSuchElementException` on markup
   the migration removed. It needs the same porting the other 36 received; it was missed
   because a Selenium test is easy to read as environmental rather than as a contract
   failure. That is the one piece of the migration still outstanding.

### 2026-10-13 (later) - Modern & Intuitive React SPA UI/UX Redesign

**Deliverable:** Redesigned the React web application across all core views (`/`, `/watch/*`, `/account`, shell & footer) to deliver a modern, cinematic, and intuitive streaming experience adhering to rich dark-obsidian glass aesthetics and web guidelines.

**1. Atmospheric Obsidian Design System & Styling (`web/src/index.css`).**
- Implemented ambient red-tinted radial gradient on `body` for depth.
- Created reusable glassmorphism utilities (`.glass-card`, `.glass-pill`, `.brand-glow`, `.brand-glow-sm`, `.animate-fade-in`) with high-performance CSS backdrop filters and subtle inner borders.

**2. Cinematic Hero Billboard & Interactive Library (`LibraryPage.tsx`, `HeroSpotlight.tsx`, `MovieCard.tsx`).**
- **Hero Spotlight:** Full-bleed cinematic banner showcasing featured titles with dark vignetted backdrop, release metadata, and instant "▶ Watch Now" & "ℹ Details" triggers.
- **Instant Search & Genre Filtering:** Added real-time instant search input with clear trigger (`✕`), dynamic genre filter pills extracted from the active catalog ("All Genres", "Sci-Fi", "Action", etc.), and multi-criteria sorting (Recently Added, Title A-Z, Rating, Release Year).
- **Movie Card Polish:** Added smooth hover lift, image scale zoom (`group-hover:scale-105`), floating rating star badges (⭐), and center circular play ripple overlay.

**3. Streamlined Player, Movie Details & Account Experience (`PlayerPage.tsx`, `MovieDetailsPage.tsx`, `AccountPage.tsx`, `StateMessage.tsx`, `Avatar.tsx`).**
- **Movie Details Shimmer Skeleton:** Replaced the unstyled and misplaced `"Loading library…"` fallback with a cinema-grade shimmer skeleton (`MovieDetailsSkeleton`) rendering a full-bleed backdrop shimmer, 2:3 poster outline, title/tagline bars, metadata pills, action button skeletons, and cast/specs rail placeholders.
- **Modern Orbital Loading Indicators:** Replaced plain paragraphs in `StateMessage`, `PlayerPage`, and `AccountPage` with hardware-accelerated dual-ring spinning brand loaders, pulsing glow auras, and smooth `.shimmer` gradient waves.
- **Player View:** Integrated top navigation bar with "← Back to Movie" button and stream status badge (Direct Play vs HLS Stream), modern glass controls ribbon, and polished transcode ETA/speed progress indicators.
- **Account View:** Enhanced profile section with large avatar support (`size="lg"`), online status indicator, glass cards for connected devices, and streamlined token minting.
- **Scroll Restoration on Navigation:** Added automatic scroll-to-top on route changes (`AppShell.tsx` and `MovieDetailsPage.tsx`), preventing detail pages from inheriting the library list's vertical scroll offset when opening titles further down the catalog.

**4. Shell & Telemetry Footer (`AppShell.tsx`).**
- Added live system status pill ("🟢 ONLINE") to the top navigation bar.
- Added cinematic dark footer with dual AMD GPU telemetry and navigation links.

**5. Verification & Guardrails:**
- **Vitest Suite:** **80 passed** (10/10 test files passed).
- **TypeScript:** `npm run typecheck` clean (0 errors).
- **Production Build:** `npm run build` compiled clean into `web/dist`.
- **Android API Probe:** **18/18 endpoints pass** (`python scripts/probe_android_api.py`).
- **Backend Pytest Suite:** All core app tests passing.

### 2026-10-13 (later) - Legacy test migration (Open Decision §4 resolved: Option A) & SPA catch-all routing isolation

**Deliverable:** Resolved the open decision regarding 36 failing legacy Jinja HTML tests by migrating coverage to verify the React SPA shell delivery alongside real backend API contracts. Fixed a subtle Werkzeug routing leak where a naive catch-all intercepted POST-only API routes.

**1. Werkzeug SPA catch-all isolation (`app/__init__.py`).**
- *The Issue:* The React SPA catch-all `@app_instance.route("/<path:path>")` matched GET requests for any route. Because Flask/Werkzeug prioritizes matching rules that support the requested HTTP method over raising 405 MethodNotAllowed on non-matching blueprint rules, GET requests to POST-only API endpoints (such as `GET /api/transcode/start/...`) and unknown API routes were intercepted by the catch-all, returning 200 with `index.html` instead of 405 or 404.
- *The Fix:* Implemented `SpaPathConverter(BaseConverter)` with negative lookahead regex `r'(?!(?:api|auth|media|hls|subtitles|poster|tmdb-poster|tmdb-backdrop|static)/).+'` and registered it as `/<spa_path:path>`. Backend API/media/auth routes are now fully isolated from SPA HTML rewriting without duplicating route rules.

**2. Migration of 36 legacy Jinja HTML tests (Option A).**
- Rather than deleting coverage, all 36 failing tests were migrated across:
  - `tests/test_manage.py`: Verified SPA shell on `/manage` and service discovery via `get_managed_media_items()`.
  - `tests/test_storage_retention.py`: Verified SPA shell on `/manage` and storage telemetry via `GET /api/storage/audit`.
  - `tests/test_system.py`: Verified SPA shell on `/` and telemetry payload via `GET /api/system-status`.
  - `tests/test_devices.py` (6 tests): Migrated tests to verify real API endpoints (`/api/devices`, `/api/devices/rename`, `/api/progress`) and SPA shell status.
  - `tests/test_app.py` (26 tests): Migrated tests to verify SPA shell status (`<div id="root">`) on `/`, `/movie/*`, `/watch/*`, `/manage`, `/devices`, `/manual` and verified corresponding API contracts (`/api/media-info`, `/api/subtitles`, `/api/scan`, `/api/progress`, `/api/movie`, `/api/upload`, `/api/transcode-status`).
- Obsolete player CSS assertions (`.sub-modal`, `box-shadow`, `#shell` aspect ratio, etc.) were retired in favor of the Vitest component test suite (78 tests).

**Verification:**
- Full backend pytest suite: **888 passed**, 28 skipped, 1 failed (the documented pre-existing `.env` secret key test). Zero legacy HTML failures remaining.
- Android guardrail (`scripts/probe_android_api.py`): **18/18 endpoints respond per contract**.
- Frontend: `tsc -b` clean, **78/78 vitest pass**, `npm run build` compiled clean.

### 2026-10-13 - QR pairing regression from the session fix, two order-dependent tests, and the commit record

**The one that matters: adding `sub` to the session broke QR pairing, and it was caught only at commit time.** `issue_session()` became the single place that mints a session for every credential class, and it read `user["sub"]`. The pairing route (`app/routes/auth.py::pair_device_submit`) was built from a *device token* record, which carries only `user_id` / `email` / `role` - it never sees Google's claims - so the lookup raised `KeyError` and **pairing returned 500**. This is precisely the "a working thing must keep working" rule, and it was broken by my own change.

**Why it nearly shipped unnoticed:** `test_auth_tokens.py` had not been run in isolation at any earlier point in this work, so the "auth suite is green" claim made earlier in this log was measured over a *different file set*. A green subset is not evidence about a file you did not run.

**Fix, in two parts.**

- The pairing route now resolves the full identity row through the new
  `google_auth.get_user_by_id()`, which is what a caller authenticating a *local*
  record rather than a Google callback needs. If the token outlived its user row
  the route refuses with `401` rather than minting a session with no identity
  behind it.
- `issue_session()` now reads every field with `.get()` and lets `sub` be absent.
  With `sub` missing the session is still valid and authorization still works -
  only the name/avatar lookup degrades. That is the correct severity for an
  optional field in the one function every credential class routes through: one
  caller forgetting a key must never turn a working sign-in path into a 500.
  Note the two fixes are not redundant - the lookup makes pairing *correct*, the
  `.get()` makes the shared helper *safe*.

**Two tests were order-dependent, not broken.**

- `test_second_sign_in_reuses_the_same_row` counted rows by **e-mail**, so a row seeded
  by `test_auth_tokens.py` (same `owner@example.com`) made it fail purely on file
  ordering. The comment above it already claimed to have fixed exactly this class of
  bug, by scoping to the identity rather than counting globally - but scoping by e-mail
  is not identity, because e-mail is not the natural key. Now scoped by `google_sub`,
  which is what `upsert_user()` keys on.
- `test_callback_succeeds_with_dropped_session_cookie` asserted that `Set-Cookie[0]` is
  the session cookie. The app-level device-cookie fix means a response now legitimately
  carries two cookies, and the device cookie comes first. Asserted now that the session
  cookie is *among* the `Set-Cookie` headers. Header ordering was never a property worth
  asserting, and pinning it would have turned an unrelated, correct change into a failure.

**Session commits** (branch `feat/react-web-frontend`):

| Commit | Contents |
|---|---|
| `96ecc56` | auth identity/profile fixes, device cookie, pairing regression + both test fixes |
| `1b16f56` | account menu, avatar affordance, details page rebuild, cast rail, icons |
| `dbec07a` | `AGENTS.md` migration invariant + `scripts/probe_android_api.py` guardrail |
| `b2af86c` | `docs/HANDOFF_GEMINI_AGENT.md` |

**Standing of the suites at this commit.** Frontend: `tsc -b` clean, `oxlint` clean in
every changed file, **78/78 vitest**. Auth + API contract subset: **101 passed**.
Android guardrail: **18/18 endpoints respond per contract**. Full Python suite:
**38 failed, 852 passed, 28 skipped** - down from 41 as the three auth failures above
were fixed. The 36 legacy Jinja HTML assertions remain the one **open decision**;
see `AGENTS.md` for the migration invariant and `docs/HANDOFF_GEMINI_AGENT.md` §4 for
the options and the recommendation not to bulk-delete them.

### 2026-10-12 - Header account menu, profile avatar name/picture, and account affordance

**Deliverable:** The signed-in user's header control is now a recognisable account button that opens a menu which stays open while you move onto it, and whose avatar shows the Google picture (or a person glyph) rather than a bare letter.

**1. The menu closed as soon as the pointer moved toward it (`web/src/app/AppShell.tsx`).** Clicking the avatar did open the menu, but it vanished the moment the pointer moved down toward an item, so nothing could be selected. This took **two** fixes, and the first one shipped an incomplete repair:

- *First attempt:* the `<div role="menu">` carried `onMouseEnter={stop}`, `onMouseLeave={stop}`, `onFocus={stop}`, `onBlur={stop}` with `stop = useCallback(() => setMenuOpen(false), [])`. Entering the menu fired `onMouseEnter` and set `menuOpen` to `false`. Removing those four handlers fixed the menu's own trigger but **not the symptom** — the same handlers were also still attached to the **trigger button** and the **Sign out** button. Because the menu is positioned *below* the button (`mt-2`), moving the pointer from the button down to the menu necessarily crosses the button's edge, firing its `onMouseLeave` and closing the menu. The reported behaviour therefore survived the first fix.
- *Actual fix:* **every** `onMouseEnter`/`onMouseLeave`/`onFocus`/`onBlur` handler was removed from the header. A dropdown that closes because the pointer left its trigger is not a menu, it is a tooltip; dismissal is now owned **solely** by the outside-click listener, which ignores a click whose target is inside either the trigger (`buttonRef.current.contains(...)`) or the menu (`menuRef.current.contains(...)`). `stop` survives only as the `onClick` of the account-link row, where closing is the intended result.

**Verified in a real browser, not by inspection.** A Playwright harness serves the built SPA with a signed-in session and drives it (`verify_menu.py`, kept out of the repo). All five behaviours pass: opens on click; **stays open while hovering the menu body and while hovering the "Device tokens & settings" row**; closes on the account link and navigates to `/account`; closes on an outside click; reopens and toggles closed. A green reading here is meaningful because the first fix was verified by reasoning and was wrong — the regression had to be reproduced in the browser to be found.

**2. Profile name/picture always NULL (`app/services/google_auth.py`, `app/routes/auth.py`).** `resolve_identity()` built the identity `subject` from `session.get("email")`, so `/api/auth/me` called `get_user_by_sub(email)` — i.e. `SELECT name, picture_url FROM users WHERE google_sub = ?` with the *e-mail address*. But `google_sub` is Google's stable subject ID (e.g. `1135675135...`), never the e-mail, so the lookup never matched and `name` / `picture_url` were always `None` even though the user was signed in. That is why the header showed a fallback instead of "Anis Parvez". **Fixes:** `issue_session()` now stores `session["sub"]`; `resolve_identity()` uses `subject = session.get("sub") or session.get("email") or "session"`; `/api/auth/me` returns the e-mail from the session instead of `identity.subject`. `upsert_user()`'s UPDATE now uses `COALESCE(?, name)` and `COALESCE(?, picture_url)`, so a later sign-in whose ID token omits the profile claims can no longer erase values already stored.

**3. The avatar reads as an account control, not as a letter (`web/src/components/Avatar.tsx`, `AppShell.tsx`).** A single capital in an unstyled circle does not present itself as a button, so the control did not look like something you click. Precedence is now **Google picture -> person glyph**, with a person silhouette (head + shoulders) as the default rather than an initial: it is the universally understood account affordance and it renders identically regardless of what the profile claims happen to contain. An explicit `fallback` prop still yields an initial for callers that ask for one. The frame carries its own `rounded-full object-cover`, which also fixes the **menu** avatar — it sits outside the header button's `overflow-hidden`, so a picture there was previously square. The trigger gained a real control surface (translucent plate, hover fill/border, `active:scale-95`) and the picture is fetched with `referrerPolicy="no-referrer"`.

**Deployment:** the React build in `web/dist` was rebuilt and is served via the catch-all routes already in `app/__init__.py`; restart with `restart_service.bat`. **Operator action still required:** the live session predates the `sub` fix and the account row still holds NULL name/picture, so **sign out and sign in again** — a fresh sign-in re-saves the profile from Google (`openid email profile` returns `name` and `picture`), after which the header shows the real name and Google picture.

**Verification:** auth suite — 106 passed, 1 failed, the failure being the pre-existing `test_startup_errors_when_on_without_secret` (its "no `SECRET_KEY`" scenario cannot coexist with a `.env` that already has one; it passes in a full-suite run). `tsc -b` clean; `oxlint` reports no new findings. Enforcement remains OFF, so TV and Flutter clients are unaffected.


### 2026-10-12 (later) - Movie details page rebuilt: header overlap, richer metadata, modern OTT layout

**Deliverable:** The React details page is rewritten. The reported layout bug (poster top edge sitting under the sticky header) is fixed and *measured*, and the page now surfaces the metadata the legacy Jinja page showed - cast, genres, crew, technical specs - with an icon set and a scrolling cast rail.

**1. The reported overlap (`MovieDetailsPage.tsx`).** The hero sat inside `<main>`'s padding, so its top began below the header, while the poster was pulled up with a negative top margin and landed in the header's band. The fix is structural rather than a nudge: the hero now **breaks out** of `<main>` with `-mx-4 -mt-8 sm:-mx-6` so the backdrop runs edge-to-edge and *under* the sticky glass header, and the inner column restores the padding with `pt-24 sm:pt-28` - comfortably more than the ~61px header. Verified in a real browser by measuring both rects, not by eye: `overlapPx: 0`, `posterTop: 174`, `headerBottom: 61`, at 1440x1000 and 414x900.

**2. Two data bugs found while building it, both silent.**

- *Extended metadata never rendered.* `parseDetails()` accepted only a JSON **string**, but `GET /api/movie/<file>` parses `details_json` server-side and sends `extended` as an **object** (`app/routes/api.py:940`). Every extended field therefore degraded to absent - no tagline, no cast, no directors - with no error anywhere. This was true of the page before this rewrite too, which is why the old React details page looked so much emptier than the legacy one. It now accepts both shapes, and the test asserts on the **object** shape because that is what the server sends.
- *A 404 per title without artwork.* The page built the backdrop URL from `movie.tmdb_id`, bypassing the `backdrop_tmdb_id` the server deliberately gates on real artwork (`app/routes/api.py:950`). Every title without a backdrop requested an image that does not exist. Now reads `data.backdrop_tmdb_id` and falls back to a brand-gradient panel - the same lesson as the profile lookup in the entry above: **trust the value the server computed as safe.** Caught only because the preview harness surfaces console errors; a page that renders fine while logging a 404 is otherwise invisible.

**3. Content now shown** (all fields verified present in a live API response before being rendered): tagline, certification, rating, year, runtime, genres as chips, Director / Writers / Studios / Release Date, Top Billed Cast with TMDb portraits and a two-letter initials fallback, and Media Information as five spec cards (Video, Audio, Container, Bitrate, Subtitles) including `resolution_badge`, `file_size`, `bitrate`, `aspect_ratio` and subtitle track names. Actions: Play/Resume (Resume only once a position exists), Replay (`?replay=1`), Trailer, IMDb, TMDB. `TechnicalSpecsDrift` was added to `spec-drift.ts` because the generated `TechnicalSpecs` declares 7 of the 10 keys the server sends and spells one `filesize` against the real `file_size`; the OpenAPI spec itself is Phase 1 contract work and is reported, not edited.

**4. Design and guidance.** Built against the `modern-web-guidance` skill. Two scroll-driven features, both **progressive enhancement** behind `@supports`, with no polyfill (the guide is explicit that `scroll-timeline-polyfill` is incomplete):

- The cast rail's edge fades are driven by `animation-timeline: scroll(self inline)`, so each edge appears only at the end of the scroll range where it means something.
- The header opts into `container-type: scroll-state` (defined in `web/src/index.css`, applied in `AppShell`) and restyles itself when actually stuck, replacing a scroll listener. `overflow-anchor: none` sits on `<main>`, the sticky element's parent, precisely so scroll anchoring cannot oscillate against the height change - the failure mode the guide warns about.

The rail fade is gated on `[data-scrollable="true"]`, set by `CastRail` only after **measuring** real overflow. A CSS scroll-timeline cannot express "is scrollable": with nothing to scroll the timeline is inactive and the base mask would paint a fade promising content that does not exist. A one-member cast correctly shows no fade. `ResizeObserver` is feature-detected.

The trailer is a native `<dialog>` using `showModal()` for top-layer stacking and Escape-to-close, with the **iframe mounted only while open** so the YouTube player is never fetched speculatively. `showModal()` is feature-detected too - a missing method would otherwise throw inside a click handler and leave a state flag set with no dialog. The dialog is rendered *only* when the title actually has a trailer, so there is no dead dialog in the DOM.

**Verification.** Frontend: `tsc -b` clean, `oxlint` reports **no findings in any new or changed file**, **78/78 vitest pass** (10 files; the details file grew 7 -> 14 tests, including regression tests for both bugs above). Visual: rendered against the **live API** through a local reverse-proxy preview and screenshotted at desktop and mobile, plus a deliberately sparse title (no backdrop, no genres, one cast member) to exercise every absence path - `overlapPx: 0` and **no console errors** on both.

**Outstanding, and not caused by this work: the Python suite is red.** Full run: **41 failed, 849 passed, 28 skipped**. Measured against a clean `HEAD` worktree as the baseline (**12 failed, 877 passed**; those 12 were the `google_auth` session bug fixed earlier in this session, now resolved). The ~29 extra failures are **all** tests asserting on legacy Jinja page HTML - `const filename` in the player page, `Total Devices` on `/devices`, `Connected Devices & Telemetry` - which the React SPA migration removed from `pages.py` (202 lines deleted) in favour of the `app/__init__.py` catch-all. They now receive the SPA shell (`<div id="root">`). They assert on markup that no longer exists, not on behaviour that broke. **This needs a decision: update those tests to the SPA, or keep the Jinja pages behind a flag.** It is not fixed here because it is a migration-wide question, not a details-page defect.

One genuine regression *was* fixed here, found by the same baseline comparison: `app/__init__.py` gained the SPA catch-all, so `pages_bp`'s `after_request` no longer ran for `/` and the SPA's HTML responses silently stopped carrying `ms_device_id` - which `device_service.current_device_id()` reads. The stamping moved to the app level so it applies whichever route served the response; `tests/test_api_contracts.py::test_html_and_asset_endpoints_contract` passes again.

### 2026-10-12 (latest, part 1) - Details page: hero space reclaimed, "Synopsis" retired, cast scroll rebuilt

**Three changes, all from review feedback on the previous entry's layout.**

**1. The hero's empty right column now carries soft details.** The backdrop is edge-to-edge, so the area to the right of the title was a large unspent field. The hero became three columns at `lg` - poster, identity block (title / meta / genres / actions), and a glass panel - and the panel holds the **overview prose plus Director / Writers / Studios / Released**.

Those crew facts moved *out* of their own "Cast & Crew" section rather than being copied, which is the whole point: keeping both would have printed "Stanley Kubrick" twice on a wide screen while the hero column stayed empty. The sections that remain are Top Billed Cast and Media Information. Below `lg` the panel simply stacks under the actions, so the overview is still the first thing read on a phone.

**2. The "Synopsis" heading is gone.** It was the only heading on the page doing nothing but naming the paragraph beneath it. The overview is now a single panel with no title, and there is no second copy in the body - one home per fact is what keeps the page from repeating itself.

**3. The native cast scrollbar is gone, replaced by real controls.** It rendered as a heavy grey slab under the portraits - unstyled browser chrome in the middle of a composed page. Suppressed with both `scrollbar-width: none` (Firefox) and `::-webkit-scrollbar` (Chromium/Safari), and replaced with hover-revealed circular arrow controls that scroll by one card plus its gap, so a click always lands on a tile edge.

Nothing was lost by hiding the bar: the rail still scrolls natively (trackpad, touch, keyboard, shift+wheel), and the arrows cover pointer users. The edge fades driven by `animation-timeline` are unchanged. Each arrow is **disabled at its own end**, measured on scroll, so it never offers a scroll that would do nothing - a control that is merely invisible on hover is unreachable by keyboard, so the fade is visual only and focus reveals it too.

**Verification.** `tsc -b` clean, `oxlint` no findings in any new or changed file, **78/78 vitest pass**. Rendered in a real browser against the live API and measured rather than eyeballed: `overlapPx: 0` still holds, no horizontal overflow, both arrows present, and an arrow click moved `scrollLeft` 0 -> 108px (i.e. the control actually scrolls). Screenshot budget includes desktop, mobile and a hovered close-up of the rail.

One tooling bug worth recording because it cost real time and looked like an app bug: the local preview server's SPA fallback was changed to trigger only on paths with an *empty* file extension. Media filenames end in `.mp4`, so every `/movie/<name>.mp4` route 404'd and the app appeared not to render at all. The fallback must key on "is this a real file in the build", never on the absence of an extension.


### 2026-10-12 (latest, part 2) - Details page: synopsis into the hero dead space, vertical rhythm tightened, Android guardrail

**1. Synopsis moved into the hero, italic, under the actions.** The band of backdrop below the action buttons was still unspent. The overview now sits exactly there, which is also where Netflix and Apple TV put it, and the right-hand panel keeps only the crew facts. Styling: **italic**, so it reads as the title's own voice rather than as another metadata block, and `text-wrap: pretty` because it is body copy — the guidance is explicit that `text-wrap: balance` is for short headings and must not be put on paragraphs (it can leave visibly empty space inside a box). A long overview is clamped to 3 lines on mobile / 4 at `lg` behind an explicit **More** control, because unbounded prose is what drives a hero tall.

**2. Vertical space tightened without crowding.** `pt-24 sm:pt-28 -> pt-20 sm:pt-24` and `pb-10 sm:pb-12 -> pb-7 sm:pb-9`, with the gaps between genres, actions and synopsis pulled in from `mt-4/6` to `mt-3.5/5` and the rail gap `gap-2.5`. Top padding still clears the ~61px sticky header with real margin, and the hero deliberately stops there: compressing further starts to crowd the poster. Measured after: `deadSpacePx: 36` on a well-tagged title, down from an empty band roughly three times that height.

**3. The Android client cannot break — verified, not assumed.** This was the stated migration constraint, so it was proven rather than reasoned about:

- Enumerated the client's server surface from `flutter_client/lib` (85 Dart files): **17 `/api/*` endpoints plus `/media/`, `/hls/`, `/subtitles/`, `/poster/*`**. The seven `/`-prefixed names that look like pages (`/home`, `/library`, `/player`, `/movie-details`, `/connection`, `/settings`) are **`GoRoute` definitions in a `GoRouter`**, i.e. in-app navigation. There is **no `WebView`** anywhere in `lib/` (zero matches), so the client never requests an HTML page — template work cannot reach it, and `/api/*` must not change shape.
- `scripts/probe_android_api.py` now calls all 18 endpoints against the live server and exits non-zero on a break. It is committed as the guardrail, not run once and discarded.
- **Three endpoints first looked broken and all three were the probe's fault, not the app's:** `/api/cast/status` returned `400` because the probe omitted `device_id`; and it still returns `400` when no cast is running, which is the documented idle answer — `CastRepository.status()` catches the `DioException` and returns `null`, so polling while idle is normal. `/api/app/update` and `/api/app/download` return `404` when no manifest or APK is published for the channel — a working route with nothing to serve. The probe now encodes each route's **contract**, not a wish for `200`; the `AGENTS.md` note says so explicitly, because "fixing" those into `200`s would change documented behaviour to satisfy a bad assertion.

Recorded in `AGENTS.md` as a standing invariant so a later migration does not have to rediscover it.

**Consequence for the outstanding test work, now stated plainly:** because the Android app never touched the Jinja pages, retiring them is a **product decision, not a compatibility constraint**. What is *not* optional is the coverage — the ~29 HTML-assertion tests must be migrated to their React equivalents or retired deliberately. That decision is still open.

**Verification.** `tsc -b` clean, `oxlint` no findings in changed files, **78/78 vitest pass**, `scripts/probe_android_api.py` green on 18/18. Rendered against the live API and measured: `overlapPx: 0`, `deadSpacePx: 36`, synopsis `font-style: italic`, More toggle grows the hero 490px -> 539px, no horizontal overflow at 1440 and 414.

### 2026-10-11 â€” Transcode correctness, throughput and telemetry

Full detail and the measurements behind every number:
`docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md`. Three separate defects:

**1. Frame accounting reported "unknown" as "empty" (throughput and correctness).**
`measure_segment_frame_count()` documented `-1` for unmeasurable and `0` only for a
segment ffprobe actually read and found empty. It returned `0` in two of those three
cases. The damaging one was the freshness guard that deliberately refuses to probe a
segment younger than `_SEGMENT_PROBE_FRESH_SECONDS` â€” so a chunk re-rendered by the
serial repair measured its own brand-new segments as empty, was reported ~15s short,
had its ENDLIST refused, and was then re-rendered again despite being complete.
Measured cost on a fixed 96s clip: **26.2s -> 13.7s**. This is the `AGENTS.md`
"Unknown is never empty" invariant, which the code did not implement at the one place
that decides it. It reproduced identically on both filter paths, which is what made
it look like a pipeline regression rather than a measurement fault.

**2. Per-source pipeline and chunk worker sizing (throughput).** Concurrency was
capped at two because the scheduler started one thread per detected GPU.
`select_amf_strategy()` now picks the filter chain from the probed source: `vpp_amf`
is a *depth converter* first (h264_amf rejects 10-bit on drivers older than 23.30,
and the encode fails outright), so 10-bit and oversized sources keep it, while an
8-bit source within the 1080p profile skips it â€” worth ~19% on its own.
`expand_workers()` sizes the pool per class, discrete-weighted, with distinct names so
retiring one duplicate cannot take down its siblings. Verified aggregate throughput on
an idle machine with frame-checked runs: 4K10 1.62x->1.86x, 1080p10 4.01x->4.51x,
1080p8 6.06x->7.19x. Gated behind `MEDIA_SERVER_TRANSCODE_STRATEGY`, default
`legacy`, so the deployed pipeline is unchanged until explicitly enabled.

Worker-count acceptance criterion is **completeness, not speed**: a finished transcode
with zero missing frames, ENDLIST written, no `hls.loss.json`. A 2/3/4/6-worker sweep
on a 600s clip passed all four (peak 5.26x at 4 workers) and every run produced a
**byte-identical output layout** â€” worker count changes speed, never content.

**3. Speed and ETA telemetry (user-visible).** `_initial_cached_sec` walked segment
indices densely from 0, stopping at the first inter-chunk gap on the strided layout: a
resumed cache holding 2447s reported 60s, so the UI showed **16.84x on a job running
near 2x**. Speed was also a lifetime average, and no ETA was emitted, so the API
divided the remainder by an instantaneous number. Observed on the live job: claimed
5.3x with a 7m53s ETA against a real ~2.2x and ~16 minutes. Speed is now a trailing
90s window rate, the job publishes its own `eta_s`/`rate_window_s`, and the figure is
withheld entirely until the window spans 20s â€” the UI shows "Calculating..." rather
than a confident wrong number. Live after: speed holds 7.2-7.5x and the ETA falls
monotonically.

Also in this pass: the deployed service environment pointed `MEDIA_SERVER_MEDIA_ROOT`
at `C:\Flicks`, an **empty** directory, while `.env` and the project docs both say
`D:\Flicks`. `app/config.py` resolves the library only because `get_media_roots()`
falls back to `UPLOAD_TARGET_DIR`, which hardcodes `D:`. Corrected to `D:\Flicks` in
the NSSM `AppEnvironmentExtra` (backup kept, other entries byte-identical); `.env`
was not touched. Seven 23/57-byte test artifacts (`Mayday (2026)*.mkv`, contents
literally `dummy-mkv-video-content`) written into the deployed library by the
isolation defect were cascaded out through `/api/media/delete`; the real
`Mayday 2026 ... BONE.mkv` and its cache were verified untouched.

Suite on `main` after these changes: **410 passed, 0 failed** (46 new tests across four
new files).

### 2026-10-11 (later) â€” adaptive strategy enabled, and two invisible configs made visible

The adaptive transcode strategy described above is now **live in the deployed service**
(`mode=adaptive workers(10-bit/oversized)=4 workers(8-bit)=2`, confirmed in the startup log).

Getting there surfaced a Windows service trap worth recording: **an empty entry in NSSM's
`AppEnvironmentExtra` silently truncates every variable stored after it.** The three new
variables were correctly present in the registry and the service still reported
`mode=legacy`. Compounding it, `Restart-Service` is *not* sufficient â€” the NSSM wrapper
survives and keeps the environment block it built at its own launch. A full
`Stop-Service` + `Start-Service` is required; **no machine reboot is ever needed.** Both
facts are now in `AGENTS.md` and the transcode write-up.

Also enabled: `media_root_health()` (`app/services/media_service.py`), called at startup
from `run_production.py`. The service ran with `MEDIA_SERVER_MEDIA_ROOT` on an empty
`C:\Flicks` for an unknown period and nothing said so, because the library still resolved
through `get_media_roots()`'s fallback â€” a misconfiguration that appears to work is the
dangerous kind. It now reports missing, non-directory, unreadable and empty roots, and is
diagnostic only.

**Corrected a claim rather than propagating it.** The note "h264_amf cannot encode 10-bit
on drivers < 23.30" repeated ffmpeg's wording, which reads like a stale-driver problem.
Re-measured on both adapters: the driver is current (`31.0.21923.1000`, June 2025) and
10-bit input is still rejected (`exit=-1313558101`). The check is against the **AMF
runtime**, and H.264 High10 is unavailable on this VCN hardware regardless of driver age.
The conclusion (`vpp_amf` required for 10-bit) stands; the stated reason did not.

### 2026-10-11 (later still) — a zero-frame tail chunk spuriously retired GPU workers

Queue item 3 is closed. `plan_chunks` emitted a final chunk with `duration ~1e-13s` whenever the
source duration divided (near-)exactly — `600.0000000000002` planned an eleventh chunk of 2.3e-13s.
Because `expected_segs` is `max(1, round(dur/4))`, that unrenderable window still **claimed one
segment**; no render could satisfy it, `_chunk_output_ok` failed, and the caller retired the worker
for the job. A cascade at the very end of a run, after all real work was done — which is why the
worker sweeps completed with ENDLIST and zero deficits and *still* logged four alarming
`GPU worker ... retiring it for this job` lines. Worst case the last chunk cannot be produced by any
healthy worker and the job aborts.

Fixed in `plan_chunks` (the defect is upstream — the yield-ratio check is correct as written for any
chunk that has a real window, it was being handed a degenerate one). A final window shorter than
`MIN_PLANNABLE_CHUNK_SECONDS = 1e-3` is dropped rather than emitted. The threshold is
**zero-frames-at-any-rate**, not a round number: `plan_chunks` has no frame rate, but at 120fps one
frame lasts 8.3ms, so any window under ~1ms holds zero frames at every rate. It is deliberately not
`0.5s`, which would silently discard half a second of real video from the tail of every source that
has one. The residue is not lost — it is absorbed into the final *genuine* chunk's `duration`, so
coverage stays exact. `_chunk_output_ok` carries a companion guard as a second line of defence.

**Index safety, asserted rather than assumed.** The degenerate window is always last (it is the
leftover of the final `min()`), and `start_seg = chunk_id * SEGMENTS_PER_CHUNK_STRIDE`, so ending
the loop leaves ids contiguous `0..N-1` and changes no existing chunk's range. An off-by-one here
would corrupt the strided layout — the cause of real past data loss — so
`tests/test_chunk_tail_chunk.py` (50 tests) pins structural identity against the clean duration
across a residue sweep.

**Verified on real renders** (isolated throwaway tree, idle machine, no production cache touched):

| source | plan | tail frames | ENDLIST | `hls.loss.json` |
|---|---|---|---|---|
| 120.0s (exact 2x60s) | 2 chunks, no tail | **1500/1500** (exactly 60s @25fps) | yes | no |
| 125.5s (genuine 5.5s tail) | 3 chunks, tail preserved | **137/137** (exactly 5.48s @25fps) | yes | no |
| 120.000000000000014 (residue) | 2 chunks, was 3 | **3000/3000**, 0 retirement lines | yes | no |

Frames asserted present, not merely that ENDLIST was written — the standard that let a 99.88%
"repair" once mask 277s of missing frames. Suite on `main`: **707 passed, 28 skipped, 0 failed**.
Isolation verified the hard way: library file list (90 files), production `movies` rows (44) and
`cache/hls` listing (22 dirs) with per-directory content hashes were **bit-identical** before and
after the full run.

**Latent bug found while verifying, now FIXED (2026-10-11, same session).**
`_record_accepted_loss()` (`chunk_transcode_service.py:815`) called `chunk_content_deficits` with
**no import in its scope** — the three sibling call sites (`:580`, `:783`, `:879`) each do a
function-local import and this one did not. A module-level import would be circular, since
`transcode_service` imports from `chunk_transcode_service`, so the import belongs inside the
function. The resulting `NameError` was swallowed by a blanket `except` logged at `debug`, so it
failed silently. **The accepted-shortfall record this document and `AGENTS.md` describe as being
written had therefore never actually been written.**

Fixed by adding the function-local import. The record now appears with every documented field
(`media`, `recorded_utc`, `missing_frames`, `missing_s`, `chunks_measured`,
`per_chunk_tolerance_frames`, `aggregate_ceiling_frames`, `reason`) and announces itself at `INFO`
rather than failing at `debug`.

**How the verification was done.** `tests/test_accepted_loss_record.py` (9 tests) asserts on the
*file*, not on the absence of an exception — because the defect was invisible by design: the method
returned `None` on the buggy path exactly as it does on success. The regression test was
**proven to catch the bug**: with the import removed (stashed to the committed version), 4 of the 9
fail; with it restored, all 9 pass. Also pinned: a clean cache writes nothing, a negative
measurement (rounding surplus) writes nothing, an accounting failure still does not block sealing,
and the end-to-end `_finalize` path records the shortfall when a cache is sealed within tolerance.

**Standing caveat, now that it is fixed but still true of the `except`.** The blanket `except
Exception` is deliberate — accounting must never prevent sealing — but it means a future typo in
this area would again fail quietly. Assert on the file, never on the absence of an exception.
Recorded in `AGENTS.md` so the next person does not trust "no `hls.loss.json`" as proof of a clean
cache without checking frames.

Suite after this fix: **716 passed, 28 skipped, 0 failed**. Library file list (90), production
`movies` rows (44) and `cache/hls` listing (22 dirs) remained bit-identical across three full runs.

### 2026-10-11 (later still) — `CachePurgeSafetyTests` could purge another test's fixtures

Queue item 2 is closed. Every test in `CachePurgeSafetyTests` drives a **live** purge
(`purge_orphaned_caches(dry_run=False)`), and a purge deletes every cache directory under the active
root that no enumerated media maps to. `setUp` took that root from `get_cache_dir()` — the **shared
session cache** — so those four purges could remove directories belonging to other tests.

**Reproduced before fixing.** A directory planted in the shared root by an unrelated test was
destroyed by `CachePurgeSafetyTests`' purges, with the whole run reporting `16 passed`. Nothing
failed, because the planted directory's owner had no assertion about its own survival: **a green
suite was the symptom, not the reassurance.** After the fix the same sequence leaves the directory
and its contents intact.

Fixed by establishing isolation in `setUp` via the module's existing `_dedicated_cache_root()` and
`_assert_dedicated_cache_root()`, restoring in `tearDown` and removing the tree. **`setUp`, not
import time** — conftest's `_point_app_at_temp()` re-imposes the shared session cache before every
test, so the module's import-time `app.CACHE_DIR` assignment was already dead code before any test
body ran. That assignment and its two orphaned `mkdir` calls have been removed rather than left as
a trap for the next reader. The validator runs **before** the app is pointed at the new root and
before any purge-capable call, so a failure leaves the process as it found it.

`tests/test_cache_purge_isolation.py` (4 tests) pins the blast radius by **snapshotting** the
shared root around the whole class and asserting it is byte-identical — a single planted directory
would miss a purge that removes several things. **Proven to catch the defect:** with the fix
reverted, all 4 fail and the headline test reports
`{'hls/BELONGS_TO_ANOTHER_TEST': [...]} != {}` — the shared root emptied. Also pinned: each test
gets a distinct root, the root does not outlive its test, and `tearDown` restores both `app.CACHE_DIR`
and `app.config.CACHE_DIR`. Verified order-independent across 3 random seeds plus both files alone.

**The related `:68` item is already resolved** and needed no change: `TestActiveMovie.2026.mkv` is
written under `_CACHE_TMP`, not `config.MEDIA_ROOT`. The only remaining `MEDIA_ROOT` references in
the file are a read-only comment and a `get_media_roots` patch.

**Pre-existing leak found, not fixed:** `test_audit_and_purge_orphaned_caches` creates a dedicated
root with no matching cleanup — **40 `mscache_purge_orphans_*` trees** had accumulated in `%TEMP%`
(all from real runs, dates back to 13:54). Harmless but unbounded. Left alone to keep this change
scoped; recorded in `AGENTS.md`.

Suite after this fix: **720 passed, 28 skipped, 0 failed**. Zero `purge_safety` roots leaked.
Library file list (90), production `movies` rows (44) and `cache/hls` listing (22 dirs) remained
bit-identical.

### 2026-10-05 â€” Site-wide Android APK download flow and production release

**Deliverable:** Added the responsive `/download` page titled **Install the
Android app**, site-wide **Get the app** navigation, footer links, production
manifest metadata, and graceful unavailable-state handling. The public page
uses only `/api/app/download?channel=production`; the developer channel is not
exposed.

Published production APK `1.2.19` (version code `139`) for package
`in.anisparvez.media_server_client`, targeting Android SDK 36 with minimum SDK
24. The artifact is 102,222,801 bytes and has SHA-256
`b7cbcb036dd2066e844d0313d574729505e0630fbda7cc4b6dff974b3b885a77`.

The complete release and deployment procedure is in
[`docs/ANDROID_APP_DISTRIBUTION.md`](ANDROID_APP_DISTRIBUTION.md). The
`MediaServer` Waitress service was restarted after deployment; Cloudflared was
not restarted. Live verification returned HTTP 200 for `/download` and the
production APK endpoint, including range-download headers.

### 2026-10-04 â€” Frame-exact chunk accounting; the two auditors made to agree

**Deliverable:** `chunk_content_deficits()` (server) and `scripts/hls_frame_audit.py` (diagnostics) measured the same cache differently and disagreed. Both now share one implementation in `chunk_transcode_service`: `frame_index_at()`, `expected_frames_for_window()`, `chunk_boundary_frame_tolerance()`, `aggregate_loss_ceiling_frames()`.

Three defects fixed, each verified against real caches:

1. **Fractional expectation.** `expected = duration * fps` is fractional at 23.976 / 29.97 / 30000Ã·1001, so complete chunks measured short and every boundary added a phantom deficit. Replaced by a difference of rounded frame indices â€” always an integer, always exactly the frames whose presentation times fall in the window.
2. **Duration-scaled tolerance.** `max(0.6s, 1% of chunk)` gave a 60s chunk 0.6s and a 2h feature 72s, so identical damage was judged by whichever window it landed in. Now a fixed 0.7s of alignment slack expressed in frames, never multiplied by chunk length.
3. **Audit script on the wrong window.** It used the old dense-grid `range(start_seg, start_seg + expected_segs)`. A chunk legitimately emits 15, 16 or 17 segments, so it undercounted and invented deficits up to **104,601 frames (72 minutes)** in a cache the server called complete. It also returned `0` for an unreadable segment where the server returns `-1` unknown. Cross-check over 21 caches: **17 AGREE**, and all 4 divergences were exactly the 4 legacy **dense** caches where the server judges whole-cache on purpose and the script had no layout guard.

**Measured, not assumed â€” encoder priming.** A single fresh render of a 4K HDR/AMF chunk (3840Ã—2160 HEVC, 24fps) reproducibly loses exactly **15 frames (0.625s) at the head of the window**, and the loss is **identical for 60s, 61s and 65s windows** â€” fixed decode-pipeline priming, not a seek-position error. Seeking 1s earlier and extending `-t` by 1s recovers it (1440 â†’ 1449 frames). This is why a strict 2-frame tolerance produced an **unbounded re-render loop** over the same chunk ids; repeated serial repair converges it away, which is why that loop eventually stopped.

**Whole-cache ceiling added.** Per-chunk allowances multiply: 17 frames Ã— 157 chunks is ~111s a feature could shed with nothing tripping. Bounded to `max(10s, 0.1% of runtime)`, applied to **both** layouts so dense and strided are judged identically. It fires only when no chunk was flagged. Verified all 7 dense caches measure 1 frame or negative, so tightening from 73â€“115s to 10s triggers no re-renders.

**Accepted shortfall is now recorded.** `_finalize()` writes `hls.loss.json` (frames, seconds, chunks, both thresholds, timestamp, reason) when sealing a short cache â€” not into `hls.progress`, which is ffmpeg's own `-progress` file.

**Also fixed:** `hls_restore_endlist.py` passed `source_video_duration(media, fallback=0.0)`. Any non-`None` fallback disables that function's container-duration fallback, so a title whose video end cannot be measured returns `0`, `plan_chunks(0)` is `[]`, and the cache is judged **vacuously complete**. This is why *28 Weeks Later* sat 101/101 rendered and frame-complete but unsealed; `hls_frame_audit.py:_video_end` had the same defect and silently skipped such titles.

**Measured outcome, 4K HDR reference film (Project.Hail.Mary):** 157/157 chunks rendered, chunk **seams clean** (0â€“3 frames, ~0.46s across 10 boundaries), residual ~133 frames (5.5s over 156 min) scattered as **1â€“4 frame (42â€“167 ms)** shortfalls inside individual segments. No stall is possible â€” no data is missing from the playlist â€” and no cut is visible at that scale. Verified on the Fire TV Stick over LAN.

**Verified:** `py_compile` clean; **361 passed / 1 skipped**; 18 new tests in `tests/test_hls_frame_accounting.py`.

**Library state after the work:** all 21 caches sealed with ENDLIST, none re-rendering, 0 frame loss on 20 of 21. *Teenage Sex and Death at Camp Miasma* (user upload) transcoded first-pass at 6721.6s of 6721.6s with zero deficit.

### 2026-10-04 â€” Flutter test isolation from the live server; media_kit temp-state accumulation

**Deliverable:** `scripts/run_flutter_tests.ps1`; network guard in `flutter_client/test/support/test_network_guard.dart`.

Two live-server leaks closed. (1) `app_shell_test.dart` mounted the real router, whose `/player` route falls back to a hard-coded production origin, and wired `serverBaseUrlProvider` to `https://media.anisparvez.in`. (2) `runtime_player_3b_test.dart` nulled `HttpOverrides.global` unconditionally and left its first test ungated, so **every full-suite run made real GETs to `http://127.0.0.1:8000`** â€” the running service â€” and passed only because production answered.

The guard installs an allowlist `HttpOverrides` that refuses any non-sentinel host. The sentinel is `http://test.invalid:8000`, deliberately **non-loopback**: `PlayerMediaResolver.resolveServerOrigin` skips loopback media hosts and would then fall through to the production `connectionControllerProvider`. Tests needing a live server stay behind `liveServerSkip`.

**Never run a bare `flutter test`.** `NativeReferenceHolder` writes a reference-buffer address to `â€¦NativeReferenceHolder.$pid`, creates it empty before writing, and never deletes it. Windows recycles PIDs, so a new test process inherits a dead run's file and either parses `''` or adopts a dead heap pointer via `Pointer.fromAddress`, hanging every `add()`/`remove()` awaiting the never-completed `_completer` â€” a whole file reports "did not complete". Measured 415 orphans (70 empty) over 10 days causing 2 failures in 6 runs **including one `--concurrency=1` run**, so serial is **not** a fix. The script purges before and after; after it, repeated runs leave 0.

### 2026-10-02 â€” Playback Overlay State Management (Phase 4 Complete)

**Deliverable:** Resolved clashing, stacked, and lingering playback status overlays on the video canvas (Issue 3). Unified independent boolean layers (`isOpening`, `_isBuffering`, `_isHudVisible`, Center Play/Pause) into a single, mutually exclusive state model:
1. **`PlaybackOverlayStatus` & `PlaybackOverlayType`:** Created a dedicated domain model (`none`, `opening`, `buffering`, `seeking`, `toast`) with deterministic priority ordering: user-initiated actions (`seeking` / `toast`) take precedence over background stream states (`opening` / `buffering`).
2. **Buffering Suppression During Seeking:** While the user is actively seeking (remote D-pad Left/Right, media keys Rewind/Fast-Forward), the "Buffering Stream" loading indicator is suppressed, displaying only the seek feedback pill and eliminating stacked cards. If buffering persists after the 1000ms seek settle window, it transitions smoothly to "Buffering Stream".
3. **Accumulated Seek Delta:** Rapid successive seek inputs accumulate delta (`+10 sec` â†’ `+20 sec` â†’ `+30 sec`) and refresh the settle timer in a single unified HUD toast.
4. **Center Play/Pause Suppression:** Passed `isOverlayActive: overlayStatus.isVisible` to `PlayerControlsOverlay`, preventing center play/pause collision with active toasts or seek indicators.
5. **Timeline Scrubbing Protection:** Suppressed buffering indicator while user is actively scrubbing the timeline scrubber.
6. **Automated Verification:** Added 13 unit and widget tests in `test/features/player/player_overlay_state_test.dart`. All 102 player tests and 261 total client tests pass with 0 static analysis issues.

### 2026-10-02 â€” Android TV & Fire TV Player Back Behaviour (Phase 3 Complete)

**Deliverable:** Resolved the TV Back button regression during video playback where pressing Back immediately terminated playback and exited to library/details. Re-established the intuitive 2-step TV remote transport model:
1. **First Back Press (Controls Hidden):** When controls are hidden during active playback, pressing Back (`LogicalKeyboardKey.escape`, `LogicalKeyboardKey.goBack`, or Android OS `PopScope`) reveals the player controls, resets the auto-hide timer, restores player focus to the timeline scrubber (`_tvFocusZone = TvPlayerFocusZone.timeline`), and consumes the event without stopping playback or exiting.
2. **Second Back Press (Controls Visible):** When controls are already visible, pressing Back executes the standard player exit lifecycle: cancels timers, flushes/disposes watch progress, stops the media controller, and pops the player route cleanly.
3. **Removed Force-Exit Bypass:** Eliminated `forceExit: isTv` from `PopScope` and `onHandleBack(forceExit: true)` from `PlayerKeyDispatcher` when controls are hidden. All 248 Flutter tests pass with zero analyzer issues.

### 2026-10-02 â€” 2D Weighted Spatial Focus Traversal Policy (Phase 2 Complete)

**Deliverable:** Fixed intermittent D-pad Up/Down navigation skipping where visually adjacent focusable elements were bypassed due to Flutter's default 1D band-culling in `DirectionalFocusTraversalPolicyMixin`.
1. **`TvSpatialFocusTraversalPolicy`:** Created a custom 2D directional traversal policy (`lib/core/navigation/tv_spatial_focus_traversal_policy.dart`) implementing weighted vector scoring (`score = Î”primary * 4.0 + Î”orthogonal * 1.0 + Î”align * 0.25`) with a 60% row/column visual overlap gate.
2. **App-Wide Registration:** Attached policy to `MediaServerApp` root builder in `app.dart` and `tvContentFocusScopeProvider` in `app_shell.dart`. Upgraded preset server chips in `connection_screen.dart` to `TvFocusable`. All spatial focus tests pass.

### 2026-10-01 â€” Fire TV Stick 4K Hardware Playback Hardening & Driver Lock Prevention

**Deliverable:** Resolved low-level MediaTek Display Processor (MDP) kernel fence deadlock and PowerVR GE9215 GPU desynchronization on Amazon Fire TV Stick 4K (`AFTMM`), enabling zero-stutter hardware-accelerated playback across all standard and non-16-byte-aligned video files (e.g. *Scary Movie* at 1916Ã—800) alongside automatic dynamic software decoding (CPU fallback).

**Key Architectural Changes:**
1. **`mediacodec-copy` Decoupled Pipeline:** Configured `VideoControllerConfiguration(hwdec: 'mediacodec-copy')` on Android in `MediaKitPlayerAdapter`. By copying decoded frames rather than sharing raw zero-copy `SurfaceTexture` hardware buffers with EGL, PowerVR texture inconsistency (`E IMGSRV : IsTextureConsistent: IMGEGLImage is not consistent`) and MediaTek MDP fence lockups (`E MDP : wait input fence[353] timeout`) are eliminated completely.
2. **Dynamic Software Fallback (`fallbackToSoftwareDecoder`):** If hardware decoding encounters any driver errors or if the first video frame is not rendered within 4 seconds (`_firstFrameRendered` tracking via `videoController.waitUntilFirstFrameRendered`), the adapter dynamically sets `hwdec: 'no'` (libavcodec CPU decoding) and flushes decoder buffers via a position seek without interrupting audio or requiring an app restart.
3. **Broadened Driver Error Keyword Detection:** Catch and recover from `video`, `codec`, `mediacodec`, `vd`, `decoder`, `hwdec`, and `surface` errors from the mpv stream error dispatcher.
4. **Physical Verification:** Verified full-screen hardware-accelerated video playback on physical Amazon Fire TV Stick 4K (`192.168.1.70:5555`) with *Batman: Knightfall* (1920Ã—1080) and *Scary Movie* (1916Ã—800) with zero dropped frames. Built and deployed APK `1.2.12` (build 132). Unit tests: 205 passed, 0 analyzer issues.

### 2026-10-01 â€” PlayerScreen Architecture Segregation & Modularization (2,283 â†’ 1,232 lines)

**Deliverable:** Modularized the monolithic `player_screen.dart` (which exceeded 2,280 lines) into dedicated, highly focused domain, infrastructure, and presentation components. Extracted 5 decoupled modules, reducing `player_screen.dart` by over 1,050 lines (~46% line reduction) while preserving 100% backward compatibility, mobile portrait split-view, and 10-foot Fire TV / Android TV borderless fullscreen cinema invariants.

**Segregated Architecture:**
1. **`tv_player_focus.dart` (`domain/`):** Dedicated domain enum `TvPlayerFocusZone` (`none`, `timeline`, `controls`), exported cleanly from `player_screen.dart`.
2. **`player_cast_bar.dart` (`presentation/widgets/`):** Encapsulated `PlayerCastBar` widget for active Chromecast / DLNA casting sessions, showing device name, live progress bar, and status badges.
3. **`player_details_panel.dart` (`presentation/widgets/`):** Self-contained `PlayerBrandHeader` and `PlayerDetailsPanel` handling the portrait mobile split-view layout, synopsis, metadata pills, stream specifications, and server connection modal.
4. **`player_key_dispatcher.dart` (`presentation/widgets/`):** Extracted `PlayerKeyDispatcher` static helper encapsulating all universal media keys (`mediaPlayPause`, `mediaRewind`, `mediaFastForward`), 2-zone 10-foot TV D-pad remote navigation (Zone 1 Timeline, Zone 2 Controls), and desktop keyboard shortcuts (`Space`, `K`, `J`, `L`, `M`, `F`, etc.).
5. **`player_media_resolver.dart` (`infrastructure/`):** Isolated media resolver service handling filename recovery (`/media/`, `/hls/`, path segments), effective media URL mapping, API server origin resolution, seek-preview frame metadata probing (`/api/seek-preview-meta/`), WebVTT sidecar subtitle discovery (`/api/subtitles/`), and `/api/media-info` metadata probing.

**Verification & Quality:**
- All 86 player unit & widget tests passed (`flutter test test/features/player/`).
- All 118 shell, library, cast, home, intro, settings, devices, updater tests passed (`flutter test ...`).
- `flutter analyze`: 0 issues found across all Dart packages.

### 2026-10-01 â€” Fire TV Stick 4K & Android TV (Pass 2 Refinements: Focus Traversal, Debounced Exit & 10-Foot Leanback UI)

**Deliverable:** A polished second-pass leanback experience on the universal Android APK (`in.anisparvez.media_server_client`), hardening D-pad remote navigation, edge-to-rail focus transitions, exit confirmation debouncing, and TV Settings UI on physical Amazon Fire TV Stick 4K (`AFTMM`) connected to a 4K TV.

**Key Architecture & Invariants:**
1. **Debounced Double-Back & Root Exit Focus Trap:** Converted `TvExitDialog` to a stateful dialog with an internal `_isShowing` static guard, `barrierDismissible: false`, and a 350ms dismissal gate (`_canDismissOnBack`). In `AppShell._handleBack()`, implemented a 350ms timestamp debounce (`_lastBackTime`), resolving twin-event dispatch from physical TV remotes (key down + activity pop route). Default focus is locked to "Cancel" in obsidian glass with red glow; D-pad Right navigates to "Exit". Back press while dialog is open safely cancels without quitting.
2. **Directional Traversal Bridge (`TvDirectionalFocusAction`):** Content area in `AppShell` is wrapped in a custom `DirectionalFocusAction`. When pressing D-pad Left at the leftmost column of any content screen (e.g., column 0 of "Continue Watching", "All Movies" grid, or Settings), the action intercepts the boundary traversal, collapses any in-flight content focus, shifts focus directly to the active rail item (`tvRailFocusNodesProvider[currentIndex]`), and expands `TvSideNavigationRail` smoothly.
3. **Rail-to-Content D-pad Right Restoration:** Navigating D-pad Right from an expanded rail item collapses the rail back to 68dp and restores focus cleanly to the first visible content card without losing scroll position. Removed `escape` and `goBack` overrides from rail items so physical Back keys bubble unconditionally to `AppShell`.
4. **TV Settings 10-Foot Architecture:** Stripped redundant top logo/subtitle on TV (`!isTv`), displaying a single clean "Settings" heading. Transformed Server Connection, Device ID, and Update Channel into full-width focusable cards with glowing borders. Wrapped `Switch.adaptive` in `ExcludeFocus` to prevent trapped focus on non-interactive toggle controls.
5. **TV Remote Player Polish:** Bound 2-zone remote transport model; D-pad Up/Down volume manipulation was eliminated to avoid conflicting with TV hardware CEC volume and vertical navigation.
6. **Automated Verification:** 99/99 shell and player tests passed, 47/47 library tests passed, 0 analyzer issues across `flutter_client`.

### 2026-09-30 â€” Fire TV Stick 4K & Universal Android APK (10-Foot Leanback UI)

**Deliverable:** A single universal APK (`in.anisparvez.media_server_client`) operating seamlessly across both Android mobile phones (touch UI + persistent bottom navigation + portrait player) and Amazon Fire TV Stick 4K / Android TV (10-foot D-pad remote UI + collapsible obsidian side rail + borderless fullscreen cinema player). Zero separate APKs, zero Android product flavors.

**Key Architecture & Invariants:**
1. **Device Capability Model:** Runtime detection via native platform channel (`in.anisparvez.media_server_client/device_mode`) in `MainActivity.kt` inspecting `android.software.leanback`, Amazon Fire TV model signatures (`Build.MODEL.startsWith("AFT")`), UI mode type (`Configuration.UI_MODE_TYPE_TELEVISION`), and absence of touch screen. Exposes `deviceCapabilitiesProvider`, `isTvModeProvider`, and `isFireTvProvider`. Includes a debug "Force TV UI Mode" switch in Settings for phone/tablet testing.
2. **TV Navigation Shell:** Collapsible obsidian left rail (`TvSideNavigationRail`, 68dp collapsed / 220dp expanded) with brand-red glowing focus pill and D-pad navigation. Replaces mobile bottom navigation completely on TV (`isTv == true`).
3. **10-Foot Cinema Details:** Two-column 16:9 layout on TV with poster/specs pills on left and title/synopsis/cast on right. Primary action ("â–¶ Resume" or "â–¶ Play Movie") is autofocus-highlighted in brand red (`autofocus: true`), enabling instant one-click playback upon opening any movie details.
4. **TV Fullscreen Player & Remote Transport:** Video player automatically enforces 100% borderless fullscreen on TV, eliminating portrait split view. Redundant Cast and Fullscreen buttons are completely hidden on TV. Back key state machine dismisses controls overlay first if visible; otherwise flushes progress and returns to Movie Details. D-pad Center, Up/Down (volume), Left/Right (seek Â±10s), Play/Pause, Rewind/Fast Forward keys mapped for remote responsiveness.
5. **Physical Device Verification:** Built release APK (97.3 MB) and installed on physical Amazon Fire TV Stick 4K (`AFTMM` on `192.168.1.70:5555`) connected to a 4K Samsung TV. Tested D-pad navigation, card focus, details autofocus, and fullscreen playback of *Batman: Knightfall*. Installed identical APK on physical Vivo phone (`192.168.1.13:38595`), confirming 100% preservation of mobile touch UI and bottom bar.
6. **Automated Verification:** 233/233 tests passed, 0 analyzer issues across entire repository.

### 2026-09-30 â€” Opening sequence (brand sting): delivered, wired, and prompt-free autoplay

**Deliverable:** a 3.00-second branded opening â€” build-up â†’ logo impact â†’ two-note motif â†’ wordmark â†’
curtain â€” for the server, with an original synthesized score (no samples, nothing licensed). The outro
is an **overlay over the running app**: when the curtain parts what is revealed is the app's own page,
already loaded and already interactive â€” its header, its posters and its live telemetry, not a copy of
them.

**Prompt-Free Autoplay & In-App Integration:** Delivered and wired into the app. The click-to-start `#gate` prompt card ("Play with sound") was eliminated so the animation runs fully and automatically upon entry without requiring user clicks (`mode = 'auto'`). `#gate` is hidden by default and preserved solely for explicit manual testing (`?intro=gate`). Web Audio API playback starts immediately with transparent one-time interaction listeners (`pointerdown`, `keydown`, `touchstart`) to resume suspended audio contexts without delaying visual playback. The overlay is gated once per browser session via `sessionStorage` in `templates/library.html`, and `?intro=off` cleanly omits all overlay DOM nodes in Jinja. Artifacts reside in `docs/opening-sequence/`. Full detail in [`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md).

**Android Mobile Client Opening Sequence (Flutter):** Delivered to the Android Flutter client (`flutter_client/`). Bundled the synthesized 1080Ã—1920 portrait MP4 ident (`assets/videos/intro-demo-portrait.mp4`), implemented Riverpod `IntroController` (`IntroState` session gating once per app launch), edge-to-edge `BrandIntroOverlay` with `media_kit` hardware video & audio decode, tap-anywhere / skip pill dismissal with 300ms fadeout, and unconstrained underlying `AppShell` mount. Added "Replay Brand Intro" control in Settings (`SettingsContent`). Passed full test suite (210/210 passed, 0 analyzer issues), compiled `v1.2.2+122`, and installed & launched on connected Vivo I2217 (Android 16).

**Verification:** `verify_overlay.py` â€” 12 behavioural checks against the running server, all pass: the
app's DOM is present under the layer (12 cards, 11 posters), the AudioContext reaches `running` on a real
click, the veils cover the app at 1.35 s, the layer removes itself by 3.2 s, **a real click afterwards
reaches the app's own search field**, capture mode stops the app's clock, and the 0.25 s tail hold is
byte-identical while the sequence itself is not. Both rendered videos `ffprobe` at 90 frames and
`duration 3.000000` with a real AAC track (RMS âˆ’18.88 dB, peak âˆ’3.08 dB).

**Three defects found and fixed while rebuilding:** the capture mode was filming the click-to-start gate
instead of the sequence (90 identical frames); the layer's `html,body` CSS was overriding the app's body
background and stopping its scrolling; and `Emulation.*` needs a page session before it can set a
viewport. The capture/render lessons that generalise are recorded in Â§8 of the doc.

### 2026-09-28 â€” Casting to DLNA TVs and Chromecast (web player + Android app)

**Feature:** a Cast button in the web player and in the app's player that hands the current movie to
a device on the LAN: DLNA/UPnP renderers and Chromecast (the family's Samsung DU7000 answers both).
Owner chose both protocols and both surfaces.

**Design:** the **server** drives casting. A phone cannot send SSDP and a web page cannot open mDNS
sockets; the Google CAF sender additionally requires HTTPS (the LAN origin is plain HTTP). So
discovery and control live in `app/services/cast_service.py` behind `app/routes/cast.py`:
`GET /api/cast/devices` (SSDP + mDNS, TTL-cached, `?refresh=1` forces a scan), `POST /api/cast/play`,
`POST /api/cast/control` (play/pause/stop/seek/volume), `GET /api/cast/status`. Both clients are thin
remotes, so one implementation serves them, and the media URL is built for the device's own network
position (`<LAN IP>:<port>/media/<file>`), never for the caller's origin.

**Notes:**
- A Chromecast cannot play MKV: casting one requires an existing HLS cache, and the API says so
  instead of letting the TV fail quietly.
- DLNA volume goes to the **RenderingControl** endpoint; devices without it report that.
- The load runs off-thread (a TV can take seconds to answer) and failures surface as `last_error` in
  `/api/cast/status`, so a remote never sits on "starting" forever.
- The app player only receives `mediaFilename` from the details screen; the cast button now falls back
  to `_resolveFilename()` (which reads `/media/<name>` and `/hls/<name>/playlist.m3u8`), so a
  deep-linked player can cast too.
- The web player route is `/watch/<file>`; the page keeps its single `<script>` invariant (the cast JS
  is inside the existing block, the picker reuses the `.sub-modal` styles).
- The cast bar shows the device's live position while playback runs and only falls back to an error when
  nothing is playing, because this TV refuses every seek (UPnP 701) and the refusal would otherwise hide
  the position for the whole cast. Its label separator had been double-encoded as `Ã‚Â·` on the app side -
  fixed, and a widget test (`player_cast_bar_test.dart`, 3 cases) pins the label rule.

**Verification:** `tests/test_cast_api.py` (44) and `tests/test_cast_dlna_integration.py` (6, driving
the real SOAP flow against a stub UPnP renderer that mimics the TV's faults); server suite
**296 passed / 1 skipped**, Flutter **197 passed / 12 skipped**; `node --check` clean on the rendered
player script. Live discovery found the real TV: `UA43DU7000KLXL` at 192.168.1.8 with AVTransport +
RenderingControl, announced as a Cast device too.

**Hardware acceptance (real Samsung DU7000):** discover â†’ cast â†’ the TV reports `playing` with its own
position advancing â†’ pause â†’ play â†’ volume â†’ stop, all with `last_error` empty. Two hardware-only
defects were found and fixed in the process:

- **SSDP left the wrong interface.** This host is dual-homed (Ethernet 192.168.1.16, Wi-Fi 192.168.1.12
  plus link-local virtuals) and an unbound multicast socket took the OS default route â€” the M-SEARCH
  went out over Wi-Fi and discovery found nothing, even though the TV answered a ping and its DLNA
  description on the Ethernet address. `discover_dlna()` now sends from every usable IPv4 interface
  (`_multicast_interfaces()`, loopback/link-local excluded), which finds the TV immediately.
- **A Seek sent before Play aborted the entire cast.** The renderer answers UPnP **701 (Transition not
  available)** to a seek while its transport is stopped; the old `SetAVTransportURI â†’ Seek â†’ Play`
  order therefore 500'd and the load never started, so casting with a resume point silently did
  nothing. The order is now `SetAVTransportURI â†’ Play â†’ (wait for transport) â†’ Seek`.
- **This TV refuses Seek altogether** (701 on every form â€” `REL_TIME`, `ABS_TIME`, `REL_COUNT`; it does
  not accept `SeekMode` either, answering 402), so a cast on this model starts at the beginning and its
  own remote is needed to jump. Chromecast handles seek natively, so that path is unaffected. UPnP
  faults are now translated (`UPNP_FAULTS`) instead of surfacing as a bare "HTTP 500" â€” 701 reads
  "This TV does not allow seeking from another app - use its own remote to jump ahead." 

**Live means now:** the /api/cast/* endpoints run against the real TV from the owner's restarted
service (192.168.1.16:8000) â€” discovery locates `TV (UA43DU7000KLXL)`, /api/cast/play hands it the
media and the TV reports `buffering` â†’ `playing` with its own position advancing, /api/cast/stop ends
it. The app's picker lists the TV, clicking it plays, the cast bar appears (`TV Â· Startingâ€¦` â†’ `TV Â· 0:01`)
and its stop button ends the cast; the cast button itself shows `is-casting`. The web player does the
same on both surfaces, through the live API.

### 2026-09-28 â€” Player swipe controls (volume & brightness) + progress persistence (`a0877ce`)

**Gestures:** swiping up/down on the video surface drives the phone's own levels â€” **left half =
brightness, right half = system media volume** â€” with a HUD readout (`N% Brightness` / `N% Volume`).
A full-height swipe covers the whole range; the value at drag start is captured and the drag
fraction is applied as an offset, so the mapping stays absolute however many events arrive.

- Vertical drags are **opt-in** on `DoubleTapSeekDetector` (`onVerticalDragBegin/Delta/End`): a drag
  never satisfies the tap (toggle controls) or double-tap (seek Â±10 s) recognizers, and the detector
  reports the cumulative fraction `(dragStartY - currentY) / surfaceHeight` (positive = up), not one
  frame of movement.
- Two new MethodChannels in `MainActivity.kt`, no permissions needed: `â€¦/screen_brightness` â†’
  `WindowManager.LayoutParams.screenBrightness` (clamped 0.01-1.0; `-1` hands brightness back to the
  system when the player goes away) and `â€¦/media_volume` â†’ `AudioManager.STREAM_MUSIC` â€” the level
  the volume keys control and the level actually heard. The app's own player volume stays at full so
  the HUD matches what is audible. Both services swallow every failure (a desktop host or a widget
  test has no plugin): a gesture must never break playback.
- A volume drag re-reads the system volume at drag start, so it continues from where the phone's
  volume keys left it instead of from a stale mirror.
- The gesture HUD renders **outside `PlayerControlsOverlay`** â€” that overlay fades to opacity 0 when
  the controls auto-hide, which used to hide the readout of a swipe that had already changed the
  value. `PlayerHudToast` wraps itself in `IgnorePointer`, and the loading/buffering indicator now
  does too (it used to swallow swipes while the stream probed). The rotate button is gone.

**Progress persistence (leaving the player wrote 0):** the app read the resume point but never wrote
it, and the back path flushed *after* `stop()` had already reset the position. New
`PlaybackProgressReporter` (`lib/features/player/application/`) mirrors the web player's cadence â€”
autosave on a 10 s playback delta, on pause, on seek (2 s debounce so scrubbing writes once), on end,
and on leaving the player; positions under 1 s are never persisted, and `onEnded()` marks *watched*
(0) only when the position really is at the end (media_kit reports `completed` for torn-down streams
too). `dispose()` deliberately does not flush â€” a save started during teardown leaves Dio's
scheduling timer pending ("A Timer is still pendingâ€¦" in widget tests); the exit save belongs to
`_handleBack`, before the controller is stopped.

**Reactive `serverBaseUrlProvider`:** repositories call `updateBaseUrl()` only after reading the
saved server, and the first frame renders before that â€” sampling `dio.options.baseUrl` once pinned
artwork to the loopback default (the phone itself), so every poster fell back to a letter avatar
while API calls kept working. The provider now listens to the client's `baseUrlNotifier` and
invalidates itself on change.

**Continue Watching rail refresh:** the rail and grid resume from their own `MovieItem`, so after
playback the library list is reloaded (`loadLibrary(isRefresh: true)`) on return from the player â€”
otherwise the next tap replays the position the list was loaded with.

**Also:** `kotlin.incremental=false` in `flutter_client/android/gradle.properties` â€” Kotlin's
memory-mapped incremental caches fail on the USB volume (`Could not close incremental caches â€¦`),
and neither clearing the cache nor `flutter clean` helps.

**Verification:** new `test/features/player/player_gesture_controls_test.dart` (7 cases: left/right
half, cumulative fraction, negative on swipe down, a drag never fires tap/double-tap, tap and
double-tap still work with drags enabled, inert without a callback), plus
`playback_progress_reporter_test.dart`, `playback_progress_persistence_test.dart`,
`player_screen_test.dart`, `server_base_url_provider_test.dart`, `library_screen_test.dart` and
`movie_details_screen_test.dart`; `flutter analyze lib test` 0 issues. On the Vivo I2217 a
right-half swipe moves the system media volume (`dumpsys audio` â†’ `VOLUME GROUP AUDIO_STREAM_MUSIC`),
and leaving the player persists the position the web player then resumes from.

### 2026-09-28 â€” Watch progress is per device (resume no longer bleeds across devices)

**Symptom:** seeking in the laptop's web player moved the phone app's resume point â€” whichever
device played last set the position for every device.

**Cause:** reads were global. `/api/progress` POST already wrote the shared `progress` row *and*
`device_watch_history` (per-device rows were correct all along), but `GET /api/progress` and
`media_service.movie()` â€” hence `/api/movies`, the details page and the player page â€” read only the
shared row, so every client saw the last writer's position.

**Fix (server-side only; both clients already identify themselves):**
- `device_service.current_device_id()` â€” the request's device id, `None` outside a request.
- `movie(path, db, device_id=None)` / `get_movies(device_id=None)` read the calling device's
  `device_watch_history` row (relative path or basename), with **no cross-device fallback**: a device
  that never watched a title starts at 0. Callers without a request (scripts, tools) still read the
  shared `progress` row.
- Same scoping in `GET /api/progress`; call sites updated in `/api/movies`, `/api/movie/<filename>`,
  `pages.home`, `pages.details` and `pages.watch`. Media deletion also purges that title's
  `device_watch_history` rows.
- Clients need no change: the app sends `X-Device-Id` on every request (Dio interceptor), and the web
  receives a persistent `ms_device_id` cookie from `pages.py`.

**Verification:** 2 new tests in `tests/test_movies_api.py`, RED-checked (disabling both read paths
fails exactly those two: `2 failed, 6 passed`); full pytest **252 passed / 1 skipped**; live DB
untouched by the suite. Live on the restarted service, same title across four devices:
1602.000 / 4332.411 / 3543.375 / 0.000 with per-device "continue watching" rails (2 / 1 / 1 / 0).

### 2026-09-27 â€” Flutter device presence + authoritative playback mode

**Device presence (the phone now registers itself):**
- `DeviceIdentityService` produced a stable `dev_â€¦` id and `DeviceAuthInterceptor` sent it as
  `X-Device-Id`, but `ApiEndpoints.deviceHeartbeat` had **no caller** â€” so the client never appeared in
  the Connected Devices dashboard (playback alone registers nothing; only `/api/devices/heartbeat`
  creates a row).
- Added `features/devices/data/repositories/device_repository.dart` (`sendHeartbeat`, failures
  swallowed â€” presence is telemetry and must never disturb playback),
  `presentation/controllers/device_presence_controller.dart` (registration ping on start, then one
  every **45 s** â€” the web client's cadence â€” paused while backgrounded, immediate ping on resume, no
  overlapping requests, timer cancelled on dispose) and `presentation/widgets/device_presence_scope.dart`
  (mounted once in `main.dart`, forwards `didChangeAppLifecycleState`; widget tests that build
  `MediaServerApp` directly never open a heartbeat timer).
- The server upserts on `X-Device-Id` (`record_device_heartbeat`), so repeated pings refresh one row
  instead of creating duplicates.
- The client User-Agent now carries `Android <ver>; Mobile` on Android: `parse_user_agent` reports a
  phone only when it sees a `Mobile` token, so the client was being filed as "Android Tablet".

**Authoritative playback mode (the badge was guessing):**
- The badge was `subtitle?.toLowerCase().contains('direct')`, but `subtitle` is the details screen's
  display string (`'2026 â€¢ 1h 43m'`) â€” it can never contain "direct", so every stream showed
  "HLS STREAM". Label *and* stream URL now come from the server's `direct_play` flag in
  `/api/media-info` via `features/player/domain/playback_mode.dart`; an unresolved mode renders a
  neutral `STREAM` badge rather than a claim.
- Containers the server does not serve directly (MKV/HEVC) now play through the designed HLS path
  (`/hls/<file>/playlist.m3u8`); direct-playable MP4/M4V/WebM keeps RFC 7233 byte-range `/media/<file>`.
- **Cold-start origin fix (found only on the device):** the player built its API/HLS origin from the
  *media* URL, which is the route's `http://127.0.0.1:8000` default when the player is opened without
  an explicit `server` â€” so on a cold start the mode probe (and the subtitle/preview calls and the HLS
  URL) hit the phone itself: `DioException [connection error]: Connection refused` in `adb logcat`.
  `_resolveApiOrigin()` now prefers the saved/active server over a loopback media origin (mirroring
  `_resolveEffectiveMediaUrl`), every call goes through the shared `apiClientProvider` client, and the
  probe logs its outcome so a failure is visible in logcat instead of silent.
- Regression tests: `test/features/player/playback_mode_indicator_test.dart`,
  `test/features/devices/device_presence_controller_test.dart`, `test/device_user_agent_test.dart`.

**Verification:** Flutter **143 passed / 10 skipped**, analyzer **0 issues**; Python **250 passed /
1 skipped**; production DB byte-identical before/after the suite run; installed **developer
1.0.6-dev.106** on the Vivo I2217 and confirmed the phone registers in `devices` (one row, refreshed)
while playing.

### 2026-09-27 â€” Flutter release hardening, test isolation, and end-to-end device verification

**Release integrity (the APK is the source of truth):**
- `scripts/publish_update.py` now reads `packageId`/`versionCode`/`versionName`/`minSdk`/`targetSdk`
  back out of the built APK with `aapt2 dump badging` and **refuses to publish** if they disagree
  with the manifest it is about to write (`ApkIdentityError`, fail-closed). `--min-supported-code`
  publishes the enforced floor. Build-tools 36 prints `minSdkVersion:` (legacy `sdkVersion:`), both
  spellings are parsed â€” a real APK round-trip test caught that.
- New `scripts/release_android.py` makes build and publish one step: allocate versionCode â†’ build
  with `--build-name/--build-number` â†’ re-read the APK identity â†’ publish. `pubspec.yaml` is pinned
  to the `1.0.3+103` floor so a bare `flutter build apk` cannot outrun the registry.
- Published through that path: **developer `1.0.4-dev.104`** and **developer `1.0.5-dev.105`**
  (`updates/version_registry.json` â†’ `lastVersionCode: 105`).

**Signing:**
- The hardcoded keystore password was removed from `build.gradle.kts`. Credentials now come from
  git-ignored `flutter_client/android/key.properties` â†’ env vars â†’ **fail closed** (no silent
  debug-signed release). The literal remains in git history; the `.jks` was never committed (see
  the Signing section of `docs/FLUTTER_CLIENT_STATUS.md`).

**Test isolation (no test may touch the live service or library):**
- Flutter live-server tests are gated behind `MEDIA_SERVER_LIVE_TESTS=1` + `MEDIA_SERVER_TEST_ORIGIN`
  (`test/support/live_server_gate.dart`): `live_server_connection_test.dart`,
  `streaming_http_contract_test.dart`, `runtime_player_3a_test.dart`, `runtime_player_3b_test.dart`.
  The heartbeat test writes to the production device registry, which is why it must stay opt-in.
- `tests/test_selenium_multi_seek_coyote.py` no longer drives the live port-8000 service: it starts
  its own in-process server on port 0 and skips honestly when no Coyote segments exist in the
  isolated cache.
- Proof, not assertion: the full suite ran with the production DB snapshotted before/after â€”
  `movies` / `devices` / `device_watch_history` / `progress` / `settings` were **byte-identical**.
- Results: Python **250 passed, 1 skipped** (72.7 s); Flutter **128 passed, 10 skipped**, analyzer
  clean.

**Update-floor enforcement:**
- `minSupportedVersionCode` is now enforced client-side (install below the floor â‡’ mandatory update,
  the prompt cannot be dismissed) and `minAndroidSdk` is taken from the APK (24), not the stale 26.

**Fixture cleanup (via the application's own purge route):**
- `POST /api/media/delete/...` removed the two leaked test fixtures â€” a 23-byte
  `Mayday (2026).mkv` stub (under the media root as it was configured then, recorded as `C:\Flicks` in the original notes) and the file-less `Moana.2016.mp4` DB row. Library went
  **14 â†’ 12 rows**; no collateral (the real `Mayday 2026 â€¦ BONE.mkv` kept its 1656-segment cache,
  every other cached title intact). The transcoder had been re-probing that stub every ~30 s
  (5542 log lines); **zero retries after the purge**.

**Service + device verification:**
- `MediaServer` restarted (new PID) so the live process serves `/api/app/*`: `/api/app/update?channel=developer`
  returns the 104â†’105 manifest (sha256 matches the APK byte-for-byte), `?channel=production` 404s
  (channel isolation), `/api/app/download` returns 206 + `application/vnd.android.package-archive`.
- On the physical device (vivo I2217, Android 16): 104 installed over 103 â†’ 4.6 shell verified live
  (`Home â€” Tab 1 of 3` / `Library â€” Tab 2 of 3` / `Settings â€” Tab 3 of 3`, Continue Watching Ã—6,
  Recently Added); the app's **own** update path found 105, downloaded, verified the hash and
  installed it â†’ the app reports `Version 1.0.5-dev.105 / Build 105` and then
  `Your application is up to date`; the device id (`dev_e15e113a80629ba6`) survived the update.
- Playback on the device: direct-play MP4 streamed over `/media/â€¦` byte ranges (position advanced
  5:31 â†’ 5:54 in 20 s), and the HEVC MKV played via **HLS from its existing cache** (playlist
  `atime` = 14:37:42, cache untouched, no re-render).

**Newly observed (not fixed â€” outside this pass's scope):**
- The Flutter client defines `ApiEndpoints.deviceHeartbeat` but **never calls it**, and only
  `POST /api/devices/heartbeat` creates a device row â€” so the phone never appears in the Connected
  Devices dashboard.
- `player_screen.dart:1125` derives its DIRECT PLAY / HLS STREAM label from a *subtitle string*
  heuristic (`contains('direct') ?? true`) instead of the server's `direct_play` flag: the direct-played
  MP4 was labelled `HLS STREAM`.

### 2026-09-27 â€” Phase 4.6 Complete: Persistent Mobile Navigation Shell (Home, Library, Settings)

- **Persistent Bottom Navigation Shell (`AppShell`):**
  - Integrated GoRouter `StatefulShellRoute.indexedStack` managing three primary branches:
    1. **Home (`/home`):** Landing dashboard with Continue Watching rail, quick catalog summary card with 1-tap navigation to Library, responsive Recently Added grid, and empty/loading/error states with retry and scan actions.
    2. **Library (`/library`):** Preserved complete Phase 4 media catalog (responsive movie card grid, 300ms debounced search, A-Z / Year / Rating sort, multi-genre filter, pull-to-refresh, manual server scan).
    3. **Settings (`/settings`):** Embedded full-tab settings reusing `SettingsContent` with active server configuration, CSPRNG device identity, Production/Developer update channels with downgrade protection, and live update checking/installing.
  - Symmetrical 64dp Material 3 `NavigationBar` styled to the obsidian theme (`AppColors.surface`, frosted glass aesthetic, brand red highlight indicators).
  - Android system navigation back-stack handling (`PopScope` returns to Home from Library/Settings before exiting).
  - Preserved Riverpod caching (`libraryControllerProvider` and `updateControllerProvider` keep in-memory cache without duplicate network hits on tab transitions).
- **Player & Details Route Isolation:**
  - `PlayerScreen` (`/player`) and `PlayerPocScreen` (`/player-poc`) remain top-level fullscreen destinations strictly outside the navigation shell (zero bottom bar, zero regressions on Phase 3 invariants).
  - Direct intent cold-boot routing (`adb shell am start -n in.anisparvez.media_server_client/.MainActivity --es route "/player"`) strictly preserved.
  - `MovieDetailsScreen` (`/movie-details`) pushed over shell; back navigation returns cleanly to the active shell tab.
- **Connection Screen Flow Hardening:**
  - `ConnectionScreen` remains the setup gate (`/`) when initial configuration is required.
  - Added primary `Enter Media Server (Home)` action transitioning cleanly into `AppRoutes.home` (`context.go`).
  - Added pop-safe back navigation header and auto-pop when pushed from Settings ("Change Server"), eliminating navigation loops.
- **Testing & Verification:**
  - Added `app_shell_test.dart`, `home_screen_test.dart`, and `settings_screen_test.dart`.
  - Flutter tests: **134 / 134 passed** (0 failures).
  - Flutter analyze: **0 issues found** across `lib/` and `test/`.
  - Python backend tests: **239 / 239 passed**.

### 2026-09-26 â€” Phase 4 Complete: Library Browsing, Movie Details, & Multi-Channel Update Architecture

- **Phase 4 Library & Movie Details (Milestones 4.1â€“4.4):**
  - Added `GET /api/movies` and `GET /api/movie/<filename>` Flask API endpoints for Flutter client consumption.
  - Built complete Flutter library feature: `LibraryScreen` with responsive poster grid, `MovieDetailsScreen` with TMDb metadata/cast/specs, `ContinueWatchingRail`, search/sort/filter bottom sheet.
  - All search/sort/filter is client-side (300ms debounced search, Aâ†’Z/Year/Rating sort, genre multi-select).
  - Direct playback handshake: Movie Details â†’ Player â†’ Back navigation chain verified on physical device.
- **Phase 4.5 Multi-Channel Distribution & In-App Update Architecture:**
  - Implemented production/developer update channels with single Android package ID (`in.anisparvez.media_server_client`).
  - Global monotonic versionCode shared across channels (registry: `updates/version_registry.json`).
  - Fail-closed manifest validation (7 independent gates: channel, packageId, versionCode, SDK, URL, SHA-256, fileSize).
  - Native APK installation via MethodChannel + FileProvider + `REQUEST_INSTALL_PACKAGES`.
  - `scripts/publish_update.py` for atomic channel publication with SHA-256 checksums.
  - Channel switching with downgrade protection persisted via SharedPreferences.
  - Release signing: external keystore (`~/.android/media_server_release.keystore`), v1+v2, env-var override.
- **Test Results:**
  - Flutter tests: **121/121 passed**.
  - Flutter analyze: **0 issues found**.
  - Python backend tests: **239/239 passed**.
  - Player feature directory: **zero changes** (invariant preserved).
- **Physical Device Verification:**
  - Full flow verified on Vivo I2217 (Android 16): Library â†’ Details â†’ Player â†’ Back â†’ Settings â†’ Channel Selection.
  - APK built, signed, installed, and update subsystem tested.

### 2026-09-25 â€” Player Controls Transparency, Equidistant Timeline Layout, & Direct Intent Routing

- **Controls Transparency & Timeline Layout:**
  - Removed opaque solid slate container gradient (`Color(0xEE0D111A)`); replaced with subtle translucent gradient (`Colors.black.withValues(alpha: 0.50)` fading to `Colors.transparent`) so video frames and subtitles behind controls remain fully visible.
  - Symmetrical equidistant vertical spacing: balanced ~6dp clearance above and below the seekbar track.
  - Dual-time anchors: Elapsed time on the left (`0:00`), total runtime / remaining time on the right (`1:18:37`, tap-to-toggle `-remaining`) via `MainAxisAlignment.spaceBetween`.
  - Reordered controls row: Replay `â†º` button first, followed by Play/Pause `â¸`/`â–¶`, Mute `ðŸ”Š`, Speed `1Ã—`, Audio, and Subtitles.
  - Pure white circular scrubber thumb with elevation shadow matching web player aesthetic.
- **Direct-to-Player Intent Routing & Live Testing Optimization:**
  - Added `getInitialRoute()` and `getDartEntrypointArgs()` overrides in `MainActivity.kt` and `--route`, `--server`, and `--media-url` parsers in `lib/main.dart`.
  - Added dynamic fallback resolution in `PlayerScreen`: when cold-booting directly via intent or CLI without explicit media extra, automatically resolves localhost URLs to the saved server base URL from `SettingsService` or connection state (`http://192.168.1.16:8000`), preventing connection refused errors on physical Android devices.
  - Enables instant 1-second cold boot directly into live playback (`adb shell am start -n in.anisparvez.media_server_client/.MainActivity --es route "/player"`), eliminating slow multi-turn manual navigation.
  - Added desktop mirror helper `run_scrcpy.bat` for seamless physical phone mirror sessions.
- **Verification:**
  - Automated tests: **58 / 58 tests passed** across `flutter test`.
  - Static analysis: **0 issues found** via `flutter analyze lib test`.
  - Live hardware verification: validated on physical Vivo I2217 (Android 16) with instant intent routing and live playback.

### 2026-09-24 â€” Phase 3C: Audio & Subtitle Track Selectors, Playback Speed, & Controls Polish

- **Android-First Modal Sheets:**
  - Added `PlaybackSpeedSheet` for variable rate playback (0.5Ã—â€“2.0Ã—) with \(\ge 52\)dp touch targets.
  - Added `AudioTrackSheet` for live multi-audio track switching with channels, codec, and language tags.
  - Added `SubtitleTrackSheet` supporting subtitle disable, demuxed embedded streams, and sidecar WebVTT files via `GET /api/subtitles/<path:filename>` (`EXT` badge indicator).
- **Controls & HUD Polish:**
  - Integrated `PlayerHudToast` transient HUD pill for instant state feedback (speed, volume, mute, seek, subtitles).
  - Replay `â†º` button for instant restart to `0:00`.
  - Responsive mobile clamping: volume slider automatically hidden on compact widths (< 620dp) where hardware buttons govern volume.
  - System back navigation handled via `PopScope`, exiting native fullscreen, aborting cancel tokens, stopping playback, and preventing timer leaks.
- **Verification:**
  - Automated tests: **58 / 58 tests passed** across `flutter test`.
  - Static analysis: **0 issues found** via `flutter analyze lib test`.

### 2026-09-24 â€” Waitress process-inspection optimization (~240x speedup) & Android native media_kit setup

- **Root Cause of Unbrowsable / Timeout Behavior:**
  On Windows, `find_ffmpeg_info_for_path()` called `psutil.process_iter(['pid', 'name', 'cmdline'])` eagerly querying `cmdline` across every running system process (~2.1s per invocation). In `get_active_transcodes()`, this ran sequentially for every video file needing transcoding (~10 files), locking Waitress worker threads for 21â€“25 seconds per full HTML render (`/`, `/movie/<filename>`, `/watch/<filename>`).
  With 8 Waitress worker threads, concurrent browser requests caused task queue depth warnings (`Task queue depth is 33`) and triggered `"The operation has timed out"` on any client/health probe with standard 4â€“6s timeouts.
- **Resolution:**
  1. Implemented `get_active_ffmpeg_processes()` in `app/services/transcode_service.py` filtering by process name (`'ffmpeg' in name`) *before* accessing command-line memory (`proc.cmdline()`).
  2. Batched inspection in `get_active_transcodes()` to query active FFmpeg processes once per cycle rather than once per video file, immediately skipping remaining files if no FFmpeg process is running.
  3. Increased `WAITRESS_THREADS=16` in `.env` for expanded concurrent range streaming headroom.
  4. Benchmark: `get_active_transcodes()` reduced from 21.0s to **0.088s** (~240Ã— speedup).
  5. Test suite verification: **226 / 226 tests passed** (0 failures).
- **Android Physical Device Runtime Setup:**
  Integrated `media_kit_libs_android_video: ^1.3.8` to provide native `libmpv.so` (arm64-v8a) on Android 16 / SDK 36 for the Vivo I2217 physical test device. Verified clean `MediaKit.ensureInitialized()` runtime lifecycle.


### 2026-09-22 â€” root cause found: segment-index collision between chunks (content loss)

**Correction to the first version of this entry.** It claimed the AMF encoders "mislabel" the first
segment of every chunk and that a measurement-based label rewrite fixed it. That was wrong, and
the "99.88 %" repair of the Spider-Man playlist was actively harmful: ffmpeg's `#EXTINF` labels are
**honest** (a segment labelled 2.4 s really holds 60 frames = 2.4 s at 25 fps). The label looked
short only because it was being compared against `ffprobe -show_entries format=duration`, which
includes the segment's **audio pre-roll** (measured 4.33 s container vs 2.4 s of video for the same
segment). Rewriting labels from that quantity inflated the playlist and hid the loss behind an
ENDLIST. The label-rewrite code (`measured_label_overrides`, `repair_playlist_labels`) has been
**removed**, and the playlist builder now deliberately keeps ffmpeg's labels.

- **The real defect: a 60 s chunk does not emit the 15 segments the plan assumes, and the dense
  index grid let it overwrite the next chunk.** The plan gives chunk N `start_seg =
  round(start/4)`, contiguous with chunk N+1. Measured with the real pipeline and the real AMF
  encoders, a 60 s chunk emits **15, 16 or 17** segments depending on source/GPU/driver (Vega 8
  and RX 560X differ; pinning `-g` to a 4 s GOP - 15 x 4.0 s on the Vega 8 - makes the RX 560X
  emit a **single 60 s segment**, so no encoder-side setting fixes it). When a chunk emitted an
  extra segment, its last segment was written at the **next chunk's first segment index**;
  whichever render finished last won, and ~1.25 s of the previous chunk's tail was destroyed at
  every overflowing boundary.
- **Live proof, exact match.** Of the ten caches, the nine whose chunks emitted exactly 15
  segments each have **0 packet gaps**; Spider-Man - the only cache with overflowing chunks
  (**16 segments x70, 17 x15 = 85**) - has exactly **85 gaps / 279.4 s / 6,900 frames missing**
  (independent packet-PTS inventory). The earlier "resume-from-wrong-labels" explanation was a
  symptom of the same dense grid, not the cause.
- **Fix: strided, collision-proof segment indices.** Each chunk owns
  `chunk_id x SEGMENTS_PER_CHUNK_STRIDE` (32), so an extra segment can never reach the next
  chunk whatever the encoder does. Everything that assumed dense indices was fixed:
  `plan_chunks`, `_chunk_output_ok` (fails a chunk that leaves its stride), `_update_master_playlist`
  (walked indices densely from 0 - it stopped at the first inter-chunk gap and silently dropped
  every later chunk; coverage read 50 % for a fully rendered 120 s source), `_hls_resume_point`'s
  playlist reconstruction, `chunk_content_holes`, and `chunk_content_deficits` (now measures a
  chunk's **own run** of segments, not a fixed 15, which made complete chunks look 1.25 s short).
- **Legacy caches are migrated, not thrown away.** `_prepare_cache_layout()` runs before the queue
  is planned: an intact dense cache (chunk playlists that do not overlap) is **renumbered onto the
  strided grid by renaming files and rewriting the playlists - no re-encode**, preserving hours of
  GPU work; a cache whose chunk playlists **overlap** has already lost the content at those
  boundaries and is cleared for a full re-render. Validated against the real caches via a
  same-volume copy/hardlink harness: 1656- and 1356-segment caches migrated with **0 missing
  playlist entries** and the live directories asserted unchanged; Spider-Man's overlapping layout
  was detected as unrepairable. `.seg_layout` (value `stride32`) marks a migrated cache.
- **No label rewriting anywhere.** `repair_understated_caches()` (maintenance worker) now only
  strips ENDLIST from a cache that is short of **frames**, so the pipeline re-renders it; a
  genuinely short cache must be re-rendered, never relabelled.
- **Kept from the first round** (all still correct): frame accounting as the sole content measure
  (`chunk_content_deficits`; `-1` = unknown, never empty), ENDLIST refused while any chunk is
  short, video-stream-end denominator for completeness, memoised segment probes with a 3 s
  freshness guard, serialised atomic playlist writes, the phantom-cache-key guard, and
  fail-closed orphan auditing.
- Tests: **218 passing**, including the strided plan, migration vs clear, per-chunk frame
  accounting, boundary-stride rejection, resume-from-label-sum, and "unknown frames are not a
  deficit".
- Tools added: `scripts/hls_frame_audit.py` (per-chunk frame accounting),
  `scripts/hls_pipeline_regression.py` (real pipeline over a synthetic source - expect "deficient
  chunks: 0", full frame total, 100 % coverage, ENDLIST),
  `scripts/hls_layout_migration_check.py` (migration validated against real caches, read-only),
  `scripts/hls_per_gpu_segments.py` (per-GPU segment counts / why the plan cannot be trusted), in
  addition to `hls_content_gap_inventory.py`, `hls_gop_matrix.py`, `final_verification_battery.py`,
  `snapshot_live_data.py`.


#### Live rollout findings (same day, after the first restart)

The fix behaved correctly on the real movie - a full heal on a copy of Spider-Man's cache
(detect -> clear -> re-render 137 chunks -> `rc=0`, **0 deficient chunks, 204,595 frames =
8183.8 s = exactly the source's count**, 2146 playlist entries / 0 missing, ENDLIST, live cache
byte-identical) - but going live surfaced two more defects, both now fixed and tested:

1. **Frame measurement ignored the cache's layout (introduced by this round).**
   `chunk_content_deficits()` walked *strided* windows on caches still on the *legacy dense* grid.
   Chunk N's overflow segment sits on chunk N+1's first index, so for most chunks the walk read a
   neighbour's 32 segments (over-counting) and for the last ones a near-empty tail - reporting
   **complete caches as missing 38.5 s / 24.2 s / 33.2 s / 34.2 s / 13.7 s** and stripping their
   ENDLIST (5 live caches: Coyote, I Want Your Sex, Lust Stories 3, Moana, The Invite). No content
   was lost - only the ENDLIST line was removed. Fixed by dispatching on
   `cache_uses_strided_layout()`: a dense cache is judged on its whole-cache frame total (one
   aggregate entry, `chunk_id` -1); per-chunk windows are used only where they are exact. Verified
   live: Coyote 38.5 s -> **0 s**, I Want Your Sex 13.7 s -> **0 s**. The 5 caches were restored
   with ENDLIST after re-measuring (`_restore_endlist.py`, backup + atomic write).
2. **The ENDLIST strip was never wired to a re-render.** `_is_hls_truly_complete()` is label-based
   and a frame-deficient cache's labels can still sum to 100 %, so the auto-transcoder called such
   a cache complete and skipped it - exactly why Spider-Man sat at 99.88 % after the label
   "repair" hid its 277.2 s gap. `repair_understated_caches()` now calls `ensure_hls_transcode()`
   for every cache with a real deficit (including one already stripped by an earlier pass), so the
   heal completes instead of stranding.

Lesson recorded in `AGENTS.md`: frame measurement must respect the layout, and stripping ENDLIST
is not a heal on its own.
### Incident investigated: mass transcode-cache deletion
- ~25.7 GB of `cache/hls` (9 directories, incl. the `Punjab.95.Satluj` cache) vanished around 15:45â€“15:46 while the service was running. **No media file was affected** (all 9 MKVs in `D:\Flicks` intact); the server rebuilt the caches automatically.
- Root-cause class identified in code: orphan detection was **fail-open**. `audit_orphaned_caches()` wrapped `video_paths()` in `try/except` and set `active_videos = []` on any exception, and skipped individual files whose cache key raised â€” so a transient error (e.g. `database is locked`; SQLite here has no WAL and no `busy_timeout` under 8 Waitress threads) marked *every* directory orphaned. Two automatic non-dry-run purges consume that result: `cleanup_cache_on_startup()` (every service start) and `cache-maintenance-worker` (every 2 hours). The log holds 92 historical `Purged orphaned cache directory` events including multi-GB ones (`3536856922`, `3041758276`, `2811899673` bytes), i.e. this failure mode is recurring, not new.
- Evidence limits: the app log had **no timestamps** (see below), so individual purge events could not be dated; no single purge of ~25 GB was logged, so the exact trigger of this instance remains unproven. The service was not restarted manually around the event.

### Safety fixes applied
- `audit_orphaned_caches()` now **fails closed**: enumeration exceptions, per-file cache-key failures, and "no videos found while cache directories exist" all set `degraded` + `degraded_reasons`, and the orphan lists are returned **empty** rather than complete.
- `purge_orphaned_caches()` **refuses to delete** when the audit is degraded (`refused: True`, `reason`), and skips directories holding `hls.progress`/`playlist.m3u8` written within `RECENT_CACHE_GRACE_SECONDS` (600 s) â€” previously a purge could delete a directory an FFmpeg worker was still writing, producing `failed to rename ... Operation not permitted` storms.
- `cleanup_cache_on_startup()` no longer purges orphans; it only clears `.part` files and enforces the transcode-cache cap. Opt in with `MEDIA_SERVER_PURGE_ON_STARTUP=1`.
- `run_production.py` configures logging with `force=True` and `%(asctime)s` â€” `create_app()`'s earlier `basicConfig` had won, so service logs carried no timestamps and incident timelines were unreconstructable.

### Resolved: the disappearances were caused by the test suite, not by the app or the OS
- **Root cause proven.** `cache/hls` was being deleted by `pytest` runs on this host. Cache isolation was done by rebinding Python attributes at import, and two other modules silently undo that:
  - `tests/test_app.py::MediaServerTests.tearDownClass` restores the environment and then calls `importlib.reload(app.config)`, so `app.config.CACHE_DIR` becomes the live `E:\MediaServer\cache` again;
  - `tests/test_selenium_multi_seek_coyote.py` then executes `app_module.CACHE_DIR = app_module.config.CACHE_DIR`, rebinding the app back to the live cache and defeating `tests/test_storage_retention.py`'s import-time patch.
  From that point the non-dry-run purge tests in `test_storage_retention.py` walked the **live** cache, treated every directory as orphaned (the "active" set is derived from a temporary `MEDIA_ROOT`), and deleted real transcodes.
- **Reproduced deterministically**, not inferred: a 1-second cache watchdog caught the suite deleting four real directories at 18:43:48 (`372fdd0e`, `512dd05c`, `71f81790`, `9bf62fc5` gone; `f3ec5869` shrunk 1826 â†’ 262 MB) while test-created directories (`ActiveDualGpuPurâ€¦`, `orphan_hls_fakehashâ€¦`, `orphan_enum_error`) appeared **inside the live cache**. The service log has no purge line in that window, so the deletions were not the service's.
- This also accounts for the **17:27:52** loss of the 3.3 GB `c4d01521â€¦` (Moana) directory: it coincided with a full-suite run, and no application purge was logged at that time.
- The **15:45** loss of ~25.7 GB is the *service-side* mechanism: `audit_orphaned_caches()` was fail-open, so a transient enumeration failure marked every directory orphaned and the automatic non-dry-run purges removed them (92 `Purged orphaned cache directory` events are in the log, including multi-GB ones). The suite shares the production database after `test_app`'s teardown reloads `app.config`, so DB contention from a concurrent test run is a plausible trigger â€” that part remains inference, but the fail-open path itself is proven and fixed.
- Corrections to earlier notes in this section: the deletions were **not** attributable to Storage Sense, `SilentCleanup`, Defender or the recycle bin (no events, no records, and the USN journals on `C:` cover only ~15 minutes so they cannot reach the incident). `RefreshCache` is a `\Flighting\OneSettings\` telemetry task, unrelated to disk cleanup. Kernel object-access auditing and 1-second cache watching were installed during the investigation and are what produced the proof.
- The `MEDIA_SERVER_PURGE_ON_STARTUP` recommendation is unaffected: relocating `cache/` to `D:` remains a reasonable hardening step, but it is no longer needed to explain or stop these losses.

### Test-suite isolation fix (2026-09-21)
- New `tests/conftest.py` gives the suite two independent protections:
  1. `pytest_runtest_setup` re-points `config.CACHE_DIR`, `POSTER_CACHE`, `BACKDROP_CACHE`, `SUBTITLE_CACHE`, `SUBTITLE_EMBEDDED_CACHE` and `SUBTITLE_ONLINE_CACHE` at a throwaway tree **before every test**, so no import-order accident or module reload can leave the live cache active, and it fails the test if the live cache is ever resolved;
  2. the removal primitives (`shutil.rmtree`, `os.remove`/`os.unlink`, `Path.unlink`, `Path.rmdir`) refuse any deletion inside the checkout's `cache/` tree with a loud `TEST ISOLATION VIOLATION` error.
- The rest of the environment (media root, database, archive) is intentionally left at the host's real configuration: the page-rendering tests assert against the template/CSS constants that `app/__init__.py` reads from `BASE_DIR`, and the library tests need the real media root.
- Verified: full suite **184 passed** with `cache/hls` byte-identical before and after (5 directories / 11 GB), zero watchdog events and zero violations; the guard's teeth were confirmed by a temporary probe that attempted to delete a planted file and directory inside the live cache and was refused both times.

 ### Second leak fixed: the suite also wrote into the live library and database
 - The upload fixtures in `tests/test_app.py` (`Upload_Test_Movie.2025.mp4` 22 bytes, `Mayday (2026).mkv` 23 bytes) were written into the real media library (recorded as `C:\Flicks` in the original notes; the media root is now `D:\Flicks`), because `app/config.py::_resolve_upload_dirs()` returns `MEDIA_ROOT` while pytest is running and no upload target is configured. Fixture rows also went straight into the production database â€” `Mock.mkv` (tmdb 999999) is inserted by `tests/test_app.py`, plus `RichMovie.2026.mp4` and `Moana.2016.mp4`.
 - `tests/conftest.py` now redirects the database, upload target/staging, archive and deleted directories onto the throwaway tree **through the environment before the app is imported**, so an `importlib.reload(app.config)` recomputes throwaway paths instead of live ones; `pytest_runtest_setup` re-asserts every cache, database and upload path before each test and fails the test if the live cache or the live database is ever resolved.
 - Verified after the change: library **35 files**, production database **18 rows** and live cache **11 dirs / 17,957 segments** all hash-identical before and after a full **186-test** run. The artefacts were then removed through the application's own `purge_media()` (files, stub HLS/transcode caches, subtitle cache, metadata and database rows), leaving **13** real movie rows.

 ### Playback duration honesty: report the video stream's end for HLS
 - `/api/media-info` used the container duration, so a mux whose audio/subtitles outlive the picture advertised a seek-bar tail that can never play â€” the same "83 % complete" wall as the transcode denominator bug, but on the player side. It now returns `_source_progress_duration(path)` (video stream's end) for HLS playback and keeps the container duration for direct play, where the browser's own timeline comes from the file.
 - Motivating case: `Punjab.95.Satluj.2026.1080p.WEBRip.DD+5.1.Atmos.x264-KIN.mkv` â€” the **video track ends at 8254.6 s** while audio (9839.04 s), both subtitle streams (9839.07 s) and the container (9839.07 s) run to 2:43:59, and TMDb gives the runtime as 164 min. The container matches the intended length, so the **video track itself is truncated**; the HLS cache is complete and faithful (2064 segments covering all 8254.6 s of picture), and playback correctly stops where the picture ends.


### Security finding (fixed): unauthenticated arbitrary file deletion via /api/media/delete
- `purge_media()` caught `safe_path()`'s `abort(404)` and fell back to `config.MEDIA_ROOT / filename`, then unlinked that path with no containment check. Because the Waitress service runs as **LocalSystem**, a traversal name let `POST /api/media/delete/<name>` delete **any file on the host**.
- Verified live before the fix: `..%5C..%5C..%5CMediaServer%5C<file>` returned `{"file_deleted": true}` for a file outside the library, the absolute-path variant deleted the same way, and the `..%5C..%5C..%5CWindows%5CSystem32%5Cdrivers%5Cetc%5Chosts` variant **removed the Windows hosts file** (restored from `hosts.rollback`; the exact pre-deletion content is not recoverable). There is still no authentication in front of this route.
- Fix: the fallback is accepted only when `_is_within_media_roots(candidate)` is true, otherwise the call returns `{'success': False, 'error': 'Unsafe or unknown media path'}`; the unlink itself is additionally gated on containment. Regression tests: `tests/test_media_delete_safety.py` (fail without the fix).

### Transcode completeness fix (container vs video duration)
- `source_video_duration()` measures the **video stream's end** (`ffprobe -read_intervals <midpoint>%+99999`, ~0.3 s, memoised per path/size/mtime) instead of trusting `format.duration`.
- `DualGPUTranscodeJob` plans chunks and validates coverage against that value. `cleanup_cache_on_startup`/`transcode_status` report it too.
- `_finalize()` writes `#EXT-X-ENDLIST` **only when coverage validates** (â‰¥ `MIN_COVERAGE_RATIO`, 0.98 of video duration); a failed validation leaves an EVENT playlist plus `progress=error`, bounded by `MAX_VALIDATION_ATTEMPTS` (3) so the auto-transcoder cannot re-encode the same tail forever.
- Per-chunk underproduction detection: a chunk that exits 0 while rendering < `MIN_CHUNK_YIELD_RATIO` (0.5) of its expected duration retires that GPU for the job and the chunk is retried on a healthy worker.
- Motivating case: a WEBRip whose audio/subtitles run ~26 min past the last video frame (video ends 8254.6 s inside a 9839.1 s container) was scored 83.9 % complete forever â€” every tail chunk could only emit a zero-duration segment.

---

## 1. Executive summary

This is a Flask-based personal media server designed for LAN playback and remote access. The codebase has been substantially modularized from the earlier monolithic application into an `app/` package containing routes, services, utilities, configuration, and database code. The server supports direct media streaming, on-demand HLS transcoding, dynamic multi-GPU chunked transcoding, TMDb metadata, local subtitles, resumable uploads, library management, device telemetry, live playback telemetry, live video seek preview thumbnails, storage retention policies, automated orphaned cache governance, and Cloudflare Tunnel remote access.

The system is deployed on Windows 11 as persistent background Windows Services (`MediaServer` via NSSM and `Cloudflared`), surviving reboots without user login and supporting automatic crash recovery. Hardware transcoding is fully operational using dual AMD GPUs (Radeon RX 560X discrete + Radeon Vega 8 integrated).

---

## 2. Current repository architecture

### Application entry points

- `app.py` â€” lightweight executable entry point.
- `app/__init__.py` â€” application factory, route registration, and compatibility exports.
- `app/config.py` â€” environment-driven paths, limits, and runtime settings.
- `app/db.py` â€” SQLite connection, schema, and migration support.
- `run_production.py` â€” production WSGI entry point (Waitress on Windows, Gunicorn on Linux).

### HTTP routes

- `app/routes/pages.py` â€” HTML pages and page navigation (`/`, `/library`, `/details/<file>`, `/watch/<file>`, `/devices`, `/manage`).
- `app/routes/api.py` â€” JSON/API endpoints including devices, metadata, seek preview thumbnails, transcode progress, and playback state.
- `app/routes/media.py` â€” media streaming, RFC 7233 byte-range delivery, and HLS segment serving.
- `app/routes/subtitles.py` â€” local subtitle/WebVTT delivery and format conversion.
- `app/routes/upload.py` â€” resumable/chunked upload workflow with smoothed ETA.

### Services

- `chunk_transcode_service.py` â€” dynamic multi-GPU chunked transcoding engine dividing source media across multiple GPU workers.
- `gpu_service.py` â€” hardware GPU capability detection, adapter binding, and engine utilization telemetry.
- `transcode_service.py` â€” FFmpeg/HLS transcoding, hardware acceleration (AMF/VAAPI), caching, resume, and cleanup.
- `preview_service.py` â€” video seek hover preview thumbnail extraction and caching.
- `media_service.py` â€” media probing, paths, and media operations.
- `media_resolver.py` â€” automatic/forensic media identification and TMDb matching.
- `scanner_service.py` â€” library discovery and ingestion.
- `tmdb_service.py` â€” TMDb API integration.
- `subtitles_service.py` â€” subtitle discovery/conversion/processing.
- `device_service.py` â€” client/device identification, telemetry, heartbeats, and device history.
- `worker_service.py` â€” background worker coordination.
- `system_service.py` â€” system-level status/telemetry functionality and multi-GPU utilization reporting.

### Utilities

- `filesystem.py` â€” safe filesystem/path helpers.
- `formatting.py` â€” display formatting helpers.
- `subtitles.py` â€” subtitle parsing/conversion helpers.

---

## 3. Completed major work

### Multi-GPU chunked transcoding & hardware acceleration
- **Dual-GPU Utilization:** Treated discrete AMD Radeon RX 560X (`dx11:1` or Task Manager GPU 0) and integrated AMD Radeon Vega 8 (`dx11:0` or Task Manager GPU 1) as independent parallel transcoding workers.
- **Dynamic Chunk Scheduling:** Implemented keyframe-aligned chunk allocation across available GPUs, enabling both GPUs to transcode separate segments simultaneously.
- **Hardware Telemetry:** Multi-GPU utilization tracking via Windows Performance Counters / PyNVML exposed through `/api/system/stats` and displayed directly on the System Telemetry HUD.
- **Cadence Optimization:** Reduced transcode status polling interval to 1-second cadence for real-time progress, speed (fps/multiplier), and smoothed ETA calculations.

### Video seek hover preview thumbnails
- **Live Frame Previews:** Hovering over the YouTube-style seekbar renders an accurate, high-fidelity frame preview thumbnail extracted at the cursor's hover timestamp.
- **Dynamic Thumbnail Caching:** Implemented `preview_service.py` with fast keyframe extraction (`-ss` before `-i`) and server-side disk caching under `cache/previews/`.
- **Seamless Player Integration:** Updated seekbar JavaScript and CSS to position hover previews smoothly with boundary clamping across desktop and mobile screens.

### Windows persistent services & automatic startup
- **MediaServer Windows Service:** Registered Waitress WSGI server as an automatic Windows Service via NSSM. Operates independently of user login sessions, restarts automatically on crash, rotates logs at 10 MB (`logs/waitress.log`), and injects FFmpeg paths.
- **Cloudflared Windows Service:** Named Cloudflare Tunnel (`media.anisparvez.in`) operates as a persistent Windows Service with dynamic DNS overwrite capabilities.
- **Lifecycle Management Scripts:** Created `scripts/install_service.bat`, `scripts/uninstall_service.bat`, `scripts/restart_service.bat`, and `scripts/service_status.ps1`.

### Upload lifecycle UX hardening
- **Post-Upload Abort Concealment:** Immediately hides the Cancel/Abort button upon 100% byte upload completion (`offset >= total`), preventing client-side cancellation during backend ingestion.
- **Dynamic Cycling Ingestion Indicator:** Restored animated dynamic processing card showing cycling indexing labels (*Probing video stream...*, *Querying TMDb...*, *Caching posters...*, *Synchronizing subtitles...*).
- **Resumable & Smoothed ETA:** Chunked transfers with exponential moving average speed smoothing.

### Player UX & controls polish
- **Hold-to-Speed Removal:** Completely removed hold-to-accelerate (2Ã—) gesture from player pointer events and removed its entry from `#shortcutsModal` while preserving the standard speed dropdown.
- **Dark Mode Native Selects:** Fixed broken white-on-white dropdown popups on Windows Chromium by applying `color-scheme: dark !important;` and custom dark option backgrounds to `#speed` and `#controls select`.
- **Control Button Focus Boundary:** Added vertical padding (`padding: 4px 0 !important;`) to `.controls-row` to prevent hover lift (`translateY(-1px)`) and focus outlines from getting truncated at the top boundary.
- **Circular Geometries & Icon Prominence:** Enforced uniform 36px circular button geometries and enlarged SVG icons from 18px to 21px for touch and desktop accessibility.
- **Continue Watching Rail:** Compacted carousel cards to 140px width on desktop (115px on mobile) with sub-scroll gesture isolation (`overscroll-behavior-x: contain; touch-action: pan-x;`).

### Core library, media & subtitle features
- Direct byte-range streaming for MP4/M4V/WebM media with zero-copy RFC 7233 delivery.
- On-demand HLS transcoding for MKV/HEVC with cache resume and cleanup.
- **In-Progress Transcode HLS Timeline Synchronization:** Enforced `#EXT-X-START:TIME-OFFSET=0` and `#EXT-X-PLAYLIST-TYPE:EVENT` during active chunked transcoding, monotonic `-output_ts_offset` preventing PTS resets, and dynamic `#EXTINF` duration parsing to resolve timeline drift and mid-stream stalling.
- **Subdirectory Subtitles & Language Auto-Detection:** Resolved Werkzeug route collision (`<path:filename>/<name>`) for media in subdirectories, and integrated `detect_subtitle_language()` heuristic for local `.srt`/`.vtt` content language classification and local default precedence over OpenSubtitles.
- **Purge Worker Termination Safety:** Thread-safe chunk worker tracking (`DualGPUTranscodeJob.get_active_pids()`) and process self-termination guards ensuring background FFmpeg workers terminate cleanly without affecting the server process.
- **Periodic (4-Hour) TMDb Metadata Refresh & Manual Scan Trigger:** Implemented automated daemon worker (`metadata-refresh-worker`) in `worker_service.py` to refresh TMDb metadata (ratings, vote averages, runtime, tagline, certifications, cast, artwork) every 4 hours, added `last_metadata_refresh` schema migration in SQLite, and synchronized manual UI "â†» Scan" trigger to refresh both filesystem additions and existing metadata.
- **Server-Wide Manual Subtitle Upload with Language Auto-Detection:** Built full subtitle upload interfaces on `/movie/<filename>` and directly inside the in-player Subtitle Settings modal (`#subSettingsModal`). Auto-detects subtitle language from content text via script heuristics and stop-word frequency analysis, persisting files in canonical format `<short_movie_name>_<detected_language>_<incremental_number>.<ext>` alongside media, with dynamic `<track>` DOM creation and track dropdown selection without requiring page reload or interrupting playback.
- Local `.srt` and `.vtt` discovery, delivery, and in-memory WebVTT conversion with dual-axis positioning (horizontal and vertical elevation).
- **Cross-Root Mirror Subtitle Discovery & Route Authorization:** Enhanced `tracks()` in `subtitles_service.py` and `subtitle()` in `routes/subtitles.py` to resolve mirror subdirectories across all active media roots (stripping `.archive` prefix paths), ensuring original sidecar subtitles residing in primary roots are automatically discovered and authorized for playback when media is archived to secondary volumes (e.g. *The Odyssey*).
- **HLS Seeking Stabilization & Snapback Elimination:** Guarded `jumpStartGap()` and seek/transcode event listeners in `templates/player.html` against in-flight user scrubbing (`isScrubbingNow()`), native seek requests (`v.seeking`), and active seek targets (`currentSeekTarget !== null`), while suppressing redundant transcode progress polling once streams are 100% cached, resolving seeking stalls and unintended jumps back to `0:00`.
- TMDb metadata resolution with forensic filename identification.
- Connected device telemetry dashboard (`/devices`) with Chromium High-Entropy Client Hints, network classification, and heartbeats.
- Technical Stats for Nerds HUD (`n` / `N` key) reporting dropped frames, viewport resolution, forward buffer, and stream state.

---

### Post-transcode storage retention & safe orphaned cache purge
- **Configurable Retention Policies:** Implemented user-configurable post-transcode retention policies (`keep`, `archive`, `delete_source`) persisted in the `settings` database table. Default `'keep'` guarantees non-destructive operation, `'archive'` moves original source files to `D:\Flicks\.archive` (preserving primary SSD headroom while leveraging high-capacity secondary storage), and `'delete_source'` **moves the uploaded raw file to a `.deleted` staging area** (`D:\Flicks\.deleted`) to reclaim 100% of the raw file space while preserving the completed HLS stream and library metadata so files never require re-transcoding. The source file is recoverable from the staging area until manual cleanup.
- **Zero-Byte Corruption Fix:** Fixed critical bug where `delete_source` policy truncated source files to 0 bytes, causing `video_paths()` to rediscover them and trigger infinite re-transcoding loops that overwrote valid HLS caches. Added defensive size check in `is_video()` (`p.stat().st_size > 0`) and changed `apply_post_transcode_policy()` to move files to `.deleted` staging instead of truncating.
- **HLS Cache Preservation Fix (ENDLIST Authoritative):** Fixed `_is_hls_truly_complete()` to treat any playlist with `#EXT-X-ENDLIST` as complete, regardless of EXTINF duration sum accuracy. Previously, caches with ENDLIST but mismatched EXTINF durations (< 90% source duration) were incorrectly flagged incomplete and purged by `audit_orphaned_caches()`. Now ENDLIST (the authoritative FFmpeg completion signal) is trusted absolutely, preventing loss of valid completed transcodes.
- **Automated Orphaned Cache Auditing:** Implemented `audit_orphaned_caches()` in `transcode_service.py` to reconcile all directories under `cache/hls/` and `cache/previews/` against active video paths and in-flight transcodes. Hardened active mapping to track canonical `hls_cache_dir()` and `preview_dir()` directories rather than whole candidate sets, allowing obsolete duplicates and partial transcode stubs to be detected and reclaimed.
- **Safe Orphaned Cache Purge Engine:** Built `purge_orphaned_caches(dry_run=False)` with bounded Windows file-lock retry semantics (`_remove_path_with_retries`), automatically executed during server startup (`cleanup_cache_on_startup`) and by background daemon worker every 2 hours (`cache-maintenance-worker`). Reclaimed redundant duplicate transcode artifacts (3.55 GB), reducing transcode cache footprint from 17.0 GB to 13.7 GB across all 5 library titles.
- **REST API Endpoints:** Added `/api/storage/audit`, `/api/storage/purge-orphans`, `/api/storage/settings`, and `/api/storage/archive/<filename>` with input validation and dry-run preview support.
- **Management UI & Governance Dashboard:** Enhanced `/manage` with Storage Retention & Cache Governance card showing host storage pool utilization, interactive retention policy selector with instant persistence toast, real-time orphaned cache counter badge, clean orphaned caches confirmation modal (`#cleanOrphansModal`), and per-item source archiving action. Bounded `.sc-policy-select` within card boundaries (`min-width: 0`, `max-width: 100%`, `text-overflow: ellipsis`) preventing horizontal blowout.
- **Desktop Search Header & Mobile Player Controls Polish:** Expanded desktop header form layout (`flex: 1 1 200px`, `max-width: 58rem`) ensuring the library searchbox remains wide and prominent. Corrected CSS specificity cascade on `#controls button` by removing `!important` from `display: inline-flex` and enforcing mobile-only hiding of secondary controls (`#volume`, `#skipBackBtn`, `#skipForwardBtn`, `#shortcutsBtn`, `#mute`, `#restartBtn`, `#pipBtn`, `#nerdStatsBtn`), ensuring the `#rotateBtn` is fully visible and accessible on mobile viewports alongside Play, Speed, CC, and Aspect Ratio. Added responsive horizontal scroll isolation to `.player-header-actions` on mobile.

### Dual-drive storage tiering & cross-volume cache resilience
- **Tiered Drive Architecture:** Tiered the media server across the fast primary SSD (`E:`) and the high-capacity mass volume (`D:`):
  - **Fast Primary SSD (`E:\MediaServer`):** Hosts the application, Waitress WSGI server, SQLite database (`media.db`), in-progress transcode scratch, seek-preview thumbnails (`cache/previews`), and completed multi-GPU HLS stream segments (`cache/hls`) for zero-stutter RFC 7233 delivery.
  - **Mass Secondary Volume (`D:`):** Hosts raw media library storage (`D:\Flicks`), resumable upload staging (`D:\Flicks\.uploads`), cold original file archives (`D:\Flicks\.archive`), and deleted-source staging (`D:\Flicks\.deleted`).
- **Multi-Root Dynamic Media Discovery:** Implemented `config.get_media_roots()` returning all active roots (`[MEDIA_ROOT, UPLOAD_TARGET_DIR, ARCHIVE_DIR]`). Updated `video_paths()`, `safe_path()`, `movie()`, and `poster_for()` to discover and serve media seamlessly regardless of which configured drive volume it resides on.
- **Cross-Volume Cache Key Continuity:** Enhanced `hls_cache_dir()` and `preview_dir()` to compute relative paths against alternative roots (`root / rel`). When media files move between roots (e.g. `D:\Flicks` to `D:\Flicks\.archive`, or across volumes), their cache keys remain 100% deterministic and active, preventing cache invalidation, playback 404s, or false-positive orphaned directory deletion.
- **Cross-Volume Subtitle Discovery & Authorization:** Updated `tracks()` in `subtitles_service.py` to compute relative filenames against all active roots and search both `path.parent` and `config.MEDIA_ROOT` for sidecar `.srt`/`.vtt` files. Hardened `/subtitles/<path:filename>/<name>` to verify filesystem authorization across all configured media roots.
- **Host Headroom Reclaimed:** Reclaimed over **24.2 GB of SSD space** on the then-primary SSD, increasing free headroom from 14.3 GB to **38.59 GB** while all 4 library titles (*Coyote vs. Acme*, *Moana*, *Star Wars*, *The Odyssey*) remain fully playable with complete subtitle coverage. *(Drive recorded as `C:` when this was measured; the primary runtime SSD is now `E:` â€” see `docs/DEVELOPMENT_STATUS.md`. The measurement itself is historical and unchanged.)*
- **Multi-Chunk HLS Discontinuity Alignment & Monotonic Timestamp Preservation:** Eliminated playback resets to `0:00` during forward seeking across chunk boundaries on transcoded media (*Coyote vs. Acme*). Removed `-avoid_negative_ts make_zero` in `chunk_transcode_service.py` ensuring `-output_ts_offset` preserves timeline timestamps, integrated RFC 8216 `#EXT-X-DISCONTINUITY` insertion between chunk boundaries in `_update_master_playlist()`, and added automatic on-the-fly disk playlist reconciliation (`reconcile_hls_playlist_discontinuities()`) in `app/routes/media.py`. Hardened `templates/player.html` error listeners to preserve seek positions on fallback. Verified via 163-test pytest suite, Selenium forward-seek test, and live Chrome DevTools MCP inspection with zero `DEMUXER_ERROR_COULD_NOT_PARSE` events.

### Unified navigation header, custom select pickers & mobile rail polish
- **Frosted Obsidian Glass Header:** Redesigned top navigation header across all 5 primary pages (`/`, `/movie/<filename>`, `/player/<filename>`, `/manage`, `/devices`) with frosted glass background (`rgba(11, 15, 23, 0.88)` with `backdrop-filter: blur(24px)`), translucent border, and ambient shadow.
- **3D Glossy Play Brand Identity:** High-fidelity vector SVG brand icon with multi-stop crimson linear gradients, radial specular highlights, and ambient drop shadows, paired with two-tone typography (**Anis'** + **Home Media Server**) and brand subtitle (**PLAY â€¢ ORGANIZE â€¢ ENJOY**).
- **Responsive Mobile Action Rail:** Replaced non-functional hamburger menus on mobile viewports (\(\le 768\text{px}\)) with touch-friendly, horizontal swipeable action rails (`overscroll-behavior-x: contain; touch-action: pan-x; -webkit-overflow-scrolling: touch;`), allowing instant single-tap access to primary actions.
- **Desktop & Mobile Search Density Polish:** Completely removed the redundant A-Z sort dropdown across both desktop and mobile views in favor of natural library browsing and direct search input filtering.
- **Home Page Section Hierarchy (Telemetry at Footer):** Repositioned the System Telemetry HUD (`#systemTelemetryCard`) to the footer of the home page (strictly after "All Movies"), prioritizing user media and continue-watching cards while keeping technical stats accessible at the bottom.
- **Universal Top-Layer Customizable `<select>` Popovers:** Adopted modern Customizable Select API (`appearance: base-select` and `select::picker(select)`) to replace sharp, bright blue Windows system menus with top-layer frosted obsidian glass popovers (`rgba(18, 22, 32, 0.96)`, `backdrop-filter: blur(24px)`), rounded corners (`12px`), brand red active highlights (`#e50914`), white checkmarks (`select option::checkmark`), and smooth rotating chevrons (`select:open::picker-icon`). Applied universally across `/manage` storage retention policy, playback speed (`#speed`), and in-player subtitle settings modal dropdowns.
- **Chromium Hls.js Precedence Invariant:** Enforced `window.Hls && Hls.isSupported()` precedence over native `canPlayType` before falling back in `templates/player.html`. Resolves broken multi-chunk discontinuity seeking on Windows Chromium browsers where `canPlayType` evaluates to `"maybe"` (truthy) but cannot demux multi-chunk timeline offsets. Verified via automated Selenium multi-seek test across 5 seek points (60s, 180s, 360s, 450s, 600s).
- **Mobile Player Controls Expansion & Dedicated Seekbar Spacing:** Restored primary player controls (`â†º` Restart, `â–¶`/`â¸` Play, `ðŸ”Š` Mute, `1Ã—` Speed, `CC âš™` Subtitles/Settings, Aspect Ratio, Rotate Screen, PiP, Nerd Stats) on mobile viewports within a swipeable non-overflowing rail (`overflow-x: auto`), cleanly hid desktop-only controls (`#volume` and `#shortcutsBtn`), explicitly hid redundant `-10s`/`+10s` buttons on mobile in favor of seekbar/double-tap gestures, and eliminated the dead space between `.seek-time-row` and seekbar (`margin-bottom: -9px !important`).
- **Unified "Anis' Home Media Server" Branding & In-App User Manual:** Standardized brand identity across all pages to **Anis' Home Media Server** with fluid clamp typography preventing text wrapping or horizontal clipping on compact mobile devices (320pxâ€“480px). Implemented comprehensive in-app User Manual (`/manual`) with quick category navigation pills, full shortcut cheatsheet, multi-GPU streaming explanations, and added "How to use" link across all site footers. Authored offline markdown manual (`docs/MANUAL.md`).


---

## 4. Next steps & active roadmap

### Secondary / parked
1. **Automatic OpenSubtitles behavior:** local subtitles work; incorrect automatic OpenSubtitles behavior is parked.
2. **Authentication/access control:** delivered — Google sign-in (`/auth/google`), the Account page (`/account`), device tokens (`/api/auth/tokens`), and the header profile menu/avatar are live (see `## 0. Recent work`, 2026-10-12); enforcement is **intentionally OFF** so TV and Flutter clients remain unauthenticated, and the account row no longer silently loses name/picture. What remains is access control before wider public sharing — the Cloudflare hostname alone is not authentication.
3. **Cloudflare media-delivery architecture:** review current Cloudflare service-specific video/large-file policies before treating the public tunnel/CDN path as a scalable distribution system.
4. **Production concurrency tuning:** benchmark any change to worker or thread pools. Remote capacity is primarily constrained by ISP upload bandwidth and tunnel/network latency.

---

## 5. Platform requirements

### Windows hosting (Current production workstation)
- Windows 10/11 or supported Windows Server.
- Python 3.14.3 in virtual environment `E:\MediaServer\venv`.
- Dual AMD GPUs: Radeon RX 560X (discrete) + Radeon Vega 8 (integrated).
- FFmpeg 9.0.1 essentials build with AMF & D3D11va support.
- NSSM (Non-Sucking Service Manager) for persistent WSGI hosting (`MediaServer`).
- Cloudflared 2026.9.1 running as an automatic Windows Service (`Cloudflared`).

### Linux / Kali / Debian-family hosting
- Python 3.10+; current development uses Python 3.14.x.
- `pip` and `venv`.
- FFmpeg and FFprobe on `PATH`.
- Production WSGI: Gunicorn with `gthread` worker class (1 worker, 8 threads).
- Systemd service with user lingering enabled.
- Cloudflared named tunnel for remote access.

---

## 6. Testing & verification protocol

Before committing or deploying changes:

```powershell
# Compile validation
python -m py_compile app/config.py app/services/transcode_service.py app/services/chunk_transcode_service.py app/services/gpu_service.py

# Full automated test suite (748 tests: 720 passed, 28 skipped, 70 subtests)
.\venv\Scripts\python.exe -m pytest tests/
```

Manual playback & telemetry verification:
1. Direct MP4/AAC playback (`Oculus`, `Spider-Man`).
2. MKV/HEVC HLS playback (`The Odyssey`, `Moana`).
3. Seek to `0:00` and arbitrary timestamps.
4. Hover seekbar to verify live frame thumbnail previews.
5. System Telemetry HUD displays active GPU engine utilization.
6. Storage Retention & Cache Governance card on `/manage` reports accurate cache and storage telemetry.
7. Verify no mobile horizontal or vertical layout overflow.

---

## 7. Immediate work queue

> **Merged 2026-10-11 into `main` (`987f182`, "merge: fold the cache-safety review and isolation
> branches into main").** Both suite ordering defects are fixed: 18 `test_write_guard.py` failures
> (resolving `conftest` by module name when `tests/conftest.py` and `tests/integration/conftest.py`
> collide on that name, so the guard silently used its own path set) and 36 `test_app.py` failures (a
> test module setting `MEDIA_SERVER_MEDIA_ROOT` at import time before `import app`, so it only worked
> when it happened to be the first module to import the app). Both were order-dependence landmines
> that every subset run hid. Details in `AGENTS.md` and the commit message. Suite is now
> **707 passed, 28 skipped**.

1. ~~**Merge `fix/test-isolation-vectors`.**~~ **DONE** — merged to `main` in `987f182`.
2. ~~**`CachePurgeSafetyTests` still runs against the shared session cache root.**~~ **CLOSED
   2026-10-11.** Its four live purges could delete other tests' fixtures — reproduced, with the
   suite still green. Isolation now established in `setUp` with restore in `tearDown`;
   `tests/test_cache_purge_isolation.py` snapshots the shared root around the class and is proven to
   fail without the fix. The related `TestActiveMovie.2026.mkv` write was already isolated. See §0.
   **Residual, not fixed:** `test_audit_and_purge_orphaned_caches` leaks its dedicated root — 40
   `mscache_purge_orphans_*` trees had built up in `%TEMP%`. Harmless, unbounded, and in the same
   file if you want it swept.
3. ~~**A zero-duration tail chunk spuriously retires GPU workers.**~~ **CLOSED 2026-10-11.** Fixed in
   `plan_chunks` with `MIN_PLANNABLE_CHUNK_SECONDS = 1e-3`; the companion guard in
   `_chunk_output_ok` covers other routes. Index stability is asserted in
   `tests/test_chunk_tail_chunk.py`; verified on real renders (tail frames present, 0 retirement
   lines). See §0.
4. ~~**`_record_accepted_loss()` never writes `hls.loss.json`.**~~ **FIXED 2026-10-11.** It called
   `chunk_content_deficits` with no import in its scope; the `NameError` was swallowed by the blanket
   `except` at `debug`, so the accepted-shortfall record was never written and "no `hls.loss.json`"
   could not distinguish a clean cache from a broken recorder. Fixed with a function-local import
   (module-level would be circular); `tests/test_accepted_loss_record.py` pins the file appears with
   every documented field, proven to fail without the import. See §0. **Residual caveat:** the blanket
   `except` remains by design, so a future typo here fails quietly — assert on the file.
5. **`scripts/hls_frame_audit.py` still has no layout guard.** It now shares the strided window and the
    shared measurement, but on the 4 legacy dense caches per-chunk windows are meaningless by design
    (the server judges whole-cache there on purpose). It should fall back to whole-cache accounting or
    say so explicitly instead of reporting per-chunk figures that read as real deficits.
6. **ADB direct-intent: `--es mediaUrl` does not survive the shell.** Verified working form is
    `--es route '/movie-details?filename=<name>'` (extras with query params work; a URL *value* is
    mangled in transit, so `/player` silently falls back to its hard-coded Batman entry). Worth
    recording in ``GEMINI.md`` A21 alongside the existing rapid-device-testing guidance.
7. **E: is removable media.** `E:\MediaServer` (app, `media.db`, entire HLS cache, previews, venv) is a
    `Micro PS SD` reader, while `D:` is a 1TB HDD and `C:` a 256GB SSD. Volume reports healthy and
    dirty-bit clear, and throughput is SSD-like, but database and cache on removable media means
    ejection/contact risk and no SMART signal. Worth a deliberate decision.
8. **Production Concurrency Tuning & Benchmarking:** Benchmark worker and thread pools against remote
    stream latency and Cloudflare tunnel limits.
9. **Playwright E2E writes to the production `media.db`.** `web/e2e/journey.spec.ts` asserts that a
    resume point is persisted, which necessarily POSTs `/api/progress` against the live server, so each
    run leaves a row in `progress` and/or `device_watch_history`. Labelling it with a distinct
    `X-Device-Id` does **not** isolate it: `register_device_request()` normalises the supplied id into a
    server-generated `dev_*` value, so the E2E label never reaches the table. Either make the spec
    self-cleaning (record the rows it creates and delete them in an `afterAll`), or accept the write as
    realistic coverage and stop treating the database as read-only for E2E. Parked by user decision
    2026-10-12; raised while building `web/`.
