# Agent Instructions — Anis' Media Server

## 0. Standing working rules

These two rules govern **all** work in this repository. Added 2026-10-16.

### 0.1 Plan first, then ask for approval

Before implementing anything non-trivial, **present an implementation plan and
explicitly request approval.** Do not begin the work on the strength of having
described it.

A plan must state, at minimum:

- **Scope** — what changes and what deliberately does not.
- **Exit criteria** — how completion is judged, stated as something checkable.
- **Risks** — what could break, and how it would be caught.
- **Open decisions** — choices that are the user's to make, not defaults to pick silently.

If the plan is revised mid-implementation, re-present it before continuing.

### 0.2 Flask and Waitress are deprecated — migrate, do not extend

`app/` (Flask, `:8000`, Waitress) and its Jinja templates are **on the way out**.
Treat every new requirement as a Rust (`:8001`) requirement.

- **Do not add capability to Flask.** No new route, service, page or background
  worker in `app/`. If something is needed there today, port it to Rust instead.
- **Prefer retiring over bridging.** Each slice should *remove* a Flask
  responsibility. `rust/src/routes/proxy.rs` forwards `/auth/*`, `/api/devices/*`,
  `/api/cast/*`, `/api/storage/*`, `/api/scan`, `/api/media-info/*`,
  `/tmdb-poster/*`, `/tmdb-backdrop/*` and `/poster/*` to `:8000`. That bridge is
  temporary hybrid-hosting scaffolding and now **contradicts §9's Native
  Independence Invariant**: its endpoint list is the debt backlog, to be paid down
  natively and deleted, not extended.
- **The rollback artifact is a tagged commit, not a live code path.** Do not gate
  retirement behind "feature flags so Flask stays viable" — that keeps the thing
  being retired permanently alive.
- Keep the Flutter/Fire TV client working throughout (see §7's probe guardrail);
  `/api/*` shapes it depends on must not change underneath it.

## 1. Project identity and source of truth

- Repository: `anis7t/media-server`
- **Stack: Rust/Axum (`:8001`) + React + PostgreSQL.** Flask and Waitress (`:8000`) are **DEPRECATED and being retired as the migration proceeds.** Read `AGENTS.md` §0 for the two standing working rules that govern all new work.
- Legacy backend: Flask (not Django), modularized under `app/`. It survives only for endpoints not yet ported; do not extend it, and do not add new capability to it.
- Root `app.py` is intentionally a lightweight executable entry point; `app/__init__.py` owns the application factory and compatibility exports.
- `docs/PROJECT_STATUS.md` is the primary current handoff: it records completed work, known bugs, platform requirements, testing requirements, and the immediate work queue. Read it before substantial changes.
- **Session handoffs live in `Handoffs/`**, named `YYYY-MM-DD_HH-MM_<agent>.md` in IST. Start a session by reading the newest one: `Handoffs/2026-10-14_21-20_antigravity_issues-1-7-and-manual-complete.md` is current and carries the paste-ready prompt, the migration phase table, the known-failing and known-flaky tests, and the traps. Each handoff names the code commits it describes rather than a single `HEAD` — a handoff citing its own hash is wrong the moment it is committed — so read the newest file, and let it supersede older ones.
- **Where the migration stands** is `docs/MIGRATION_STATUS.md` (phase-by-phase P0-P7 matrix, risks, resumption sequence); the shape and per-phase exit gates it defers to are in `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`. Items marked *(reported)* in that matrix have never been re-verified under authorization and must be treated as untested code, not as progress.
- `docs/DEVELOPMENT_STATUS.md` and `docs/WINDOWS_SETUP.md` contain the detailed current Windows/AMF and persistent service state. `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md` contains the remote-access history and named-tunnel configuration.
- `docs/MULTI_GPU_CHUNKED_TRANSCODING_PROPOSAL.md` documents the dynamic multi-GPU chunked transcoding architecture implemented in `app/services/chunk_transcode_service.py` and `app/services/gpu_service.py`.
- `docs/OPENING_SEQUENCE.md` documents the brand opening-sequence overlay (brand sting, original score, frame-capture pipeline). It is **delivered and wired into the app** via `{% include 'intro-overlay.html' %}` in `templates/library.html`, gated once per browser session; the artifacts live in `docs/opening-sequence/` inside this repository.

### Brand Opening Sequence (Intro Overlay) Invariants

- **Prompt-Free Autoplay by Default:** The brand intro overlay must auto-start immediately upon library page load (`mode = 'auto'`) without requiring user interaction or displaying a click-to-start gate prompt (`#gate` must have `display: none !important;`). The gate card is reserved strictly for manual testing via `?intro=gate`.
- **Non-Blocking Web Audio Resiliency:** Browser autoplay restrictions on the Web Audio API must never block or delay visual animation playback. The 3.0-second canvas render loop and veil parting run unconditionally; Web Audio attempts immediate playback and attaches transparent, one-time document listeners (`pointerdown`, `keydown`, `touchstart`) to resume `AudioContext` seamlessly upon first user gesture.
- **Container-Controlled Session Gating:** `intro-overlay.html` must not set `sessionStorage.setItem('introSeen')` prior to the enclosing template's evaluation. Setting it prematurely causes container checks (e.g. in `library.html`) to falsely identify the current visit as already watched, calling `INTRO.finish()` and destroying the layer on frame 1.
- **Clean Jinja Query Bypass (`?intro=off`):** Always wrap the overlay include in `{% if request.args.get('intro') != 'off' %}` so that control requests render zero intro DOM nodes (`#stage`, `#gate`), ensuring test proxies and control checks receive clean, untouched HTML responses byte-for-byte.
- **Mobile Client Opening Sequence (Flutter):** Autoplays on cold boot launch in `AppShell` with hardware-accelerated portrait video (`intro-demo-portrait.mp4`), tap-anywhere or Skip button dismissal with a 300ms fadeout, session gating via `IntroController` (gated once per app launch session), non-blocking test runner safety, and manual "Replay Brand Intro" action in Settings (`SettingsContent`). Fullscreen video player routes (`/player`, `/player-poc`) remain strictly isolated.

## 2. Current architecture

```text
Browser / Client
  -> Cloudflare named tunnel: media.anisparvez.in
  -> http://127.0.0.1:8000
  -> Waitress WSGI (NSSM Windows Service)
  -> Flask routes / API
  -> services
     -> SQLite database (E:\MediaServer\media.db)
     -> transcode/preview/poster cache (E:\MediaServer\cache)
     -> local media/artwork/subtitle storage (D:\Flicks)
     -> FFmpeg/FFprobe dual-GPU chunked transcoding
        -> AMD Radeon RX 560X (discrete, dx11:1)
        -> AMD Radeon Vega 8 (integrated, dx11:0)
     -> Live frame preview cache (cache/previews/)
     -> TMDb API
```

Important modules:

- `app/config.py` — environment-driven paths and runtime settings.
- `app/db.py` — SQLite/schema/migrations.
- `app/routes/pages.py` — HTML pages.
- `app/routes/api.py` — API/device/playback/seek-preview endpoints.
- `app/routes/media.py` — byte-range media delivery and HLS segments.
- `app/routes/subtitles.py` — local subtitle/WebVTT delivery.
- `app/routes/upload.py` — resumable chunked uploads.
- `app/services/chunk_transcode_service.py` — dynamic multi-GPU chunk scheduler.
- `app/services/gpu_service.py` — GPU detection and live engine telemetry.
- `app/services/preview_service.py` — live seek hover frame extraction & caching.
- `app/services/media_service.py` — media probing/path operations.
- `app/services/media_resolver.py` — multi-source/forensic media identification.
- `app/services/scanner_service.py` — library ingestion.
- `app/services/tmdb_service.py` — TMDb integration.
- `app/services/transcode_service.py` — FFmpeg/HLS transcoding, cache/resume/cleanup.
- `app/services/subtitles_service.py` — subtitle processing.
- `app/services/device_service.py` — device telemetry/heartbeats/history.
- `app/services/worker_service.py` — background work coordination.
- `app/services/system_service.py` — system telemetry and multi-GPU utilization stats.

## 3. Completed capabilities

The current project includes:

- **Direct Play:** Zero-copy RFC 7233 byte-range playback for MP4/M4V/WebM.
- **Dynamic Multi-GPU Transcoding:** Concurrent chunk-based encoding across discrete AMD Radeon RX 560X (`dx11:1`) and integrated AMD Radeon Vega 8 (`dx11:0`).
- **Live Multi-GPU Telemetry:** Real-time hardware engine utilization tracking via Windows Performance Counters and PyNVML displayed on the System Telemetry HUD.
- **Live Seek Hover Previews:** Frame thumbnails extracted on-demand via `preview_service.py` and cached in `cache/previews/`.
- **1-Second Transcode Cadence:** High-frequency status polling for smooth progress bars, fps/speed reporting, and smoothed ETA calculations.
- **Windows Persistent Services:** `MediaServer` (Waitress via NSSM) and `Cloudflared` run as automatic Windows Services surviving reboots without user login, with crash auto-restart and 10 MB log rotation.
- **Upload Lifecycle Hardening:** Immediate Abort button concealment upon 100% upload completion and animated dynamic processing card showing cycling background indexing stages.
- **Player Controls Polish:** Removed hold-to-speed-up gesture, cleaned shortcuts cheat-sheet modal, native dark scheme select dropdowns (`color-scheme: dark !important;`), uniform 36px circular buttons, prominent 21px SVG icons, and 4px controls-row padding preventing top focus clipping.
- **Carousel Optimization:** Compacted "Continue watching" rail cards to 140px desktop / 115px mobile.
- **Dual-Axis Subtitles:** Horizontal alignment plus lowered/bottom/raised/middle/top vertical positions with playback-control cue elevation.
- **Connected Devices Dashboard:** Chromium High-Entropy Client Hints, network path detection, active/offline states, friendly renaming, and watch history.
- **In-Progress Transcode HLS Synchronization:** Enforced `#EXT-X-START:TIME-OFFSET=0` and `#EXT-X-PLAYLIST-TYPE:EVENT` during active chunked transcoding, monotonic `-output_ts_offset` preventing PTS resets, and dynamic `#EXTINF` duration parsing to resolve timeline drift and mid-stream stalling.
- **Subdirectory Subtitles & Language Auto-Detection:** Resolved Werkzeug route collision (`<path:filename>/<name>`) for media in subdirectories, and integrated `detect_subtitle_language()` heuristic for local `.srt`/`.vtt` content language classification and local default precedence over OpenSubtitles.
- **Purge Worker Termination Safety:** Thread-safe chunk worker tracking (`DualGPUTranscodeJob.get_active_pids()`) and process self-termination guards ensuring background FFmpeg workers terminate cleanly without affecting the server process.
- **Periodic (4-Hour) TMDb Metadata Refresh & Manual Scan Trigger:** Background scheduler (`metadata-refresh-worker`) in `worker_service.py` refreshing TMDb details (ratings, vote averages, runtime, tagline, cast, certification, artwork) every 4 hours, SQLite `last_metadata_refresh` schema migration, and synchronized manual UI "↻ Scan" trigger re-synchronizing metadata alongside newly discovered files.
- **Server-Wide Manual Subtitle Upload with Language Auto-Detection:** Subtitle upload interface on movie details (`/movie/<filename>`) and integrated directly inside the in-player Subtitle Settings modal (`#subSettingsModal`). Auto-detects subtitle language from content text (Unicode character analysis & NLP heuristic), saving files server-wide alongside media in the canonical format `<short_movie_name>_<detected_language>_<incremental_number>.<ext>` with dynamic in-player `<track>` insertion and zero playback disruption.
- **Post-Transcode Storage Retention & Safe Orphaned Cache Purge:** User-configurable retention policies (`keep`, `archive`, `purge_cache`) persisted in the `settings` database table, automated cache reconciliation (`audit_orphaned_caches()`), safe Windows-lock-resilient orphaned purge (`purge_orphaned_caches()`), background daemon worker (`cache-maintenance-worker`), REST API suite (`/api/storage/*`), and interactive management UI with storage pool telemetry and one-click orphan cleaning.
- **Dual-Drive Storage Tiering & Cross-Volume Cache Resilience:** Tiered architecture keeping all runtime state on the primary fast SSD `E:` — application (`E:\MediaServer`), SQLite database (`E:\MediaServer\media.db`), in-progress transcode scratch, seek-preview thumbnails, and completed HLS cache (`E:\MediaServer\cache\hls`) — while offloading cold raw media, resumable upload staging, and source archives to the high-capacity secondary drive `D:` (`D:\Flicks`, `D:\Flicks\.archive`, `D:\Flicks\.uploads`, `D:\Flicks\.deleted`). `C:` holds nothing for this project. Telemetry aggregates `D:` and `E:` into a single Storage Pool with a per-drive breakdown (`system_service.py` `target_mounts`). Includes dynamic multi-root discovery (`get_media_roots()`), cross-volume relative-path cache key preservation in `hls_cache_dir()` and `preview_dir()`, and cross-volume sidecar subtitle resolution and authorization.
- **Cross-Root Mirror Subtitle Discovery & HLS Seeking Stabilization:** Subtitle engine automatically discovers sidecar `.srt`/`.vtt` files across mirror subdirectories in any configured media root (stripping `.archive` paths) for archived media (e.g. *The Odyssey*), and player seeking event handlers guard `jumpStartGap()` and `checkPreparing()` against in-flight user scrubbing and active seeks, eliminating playback stalls and `0:00` resets.
- **Unified Navigation Header & Brand Identity:** Redesigned frosted obsidian glass header with 3D glossy play SVG brand icon, two-tone typography (**Anis'** + **Home Media Server**), subtitle (**PLAY • ORGANIZE • ENJOY**), modular SVG pill buttons, and responsive horizontal swipeable action rails across all pages (`/`, `/movie/<filename>`, `/player/<filename>`, `/manage`, `/devices`, `/manual`).
- **Universal Customizable `<select>` Popovers:** Modernized dropdown pickers using `appearance: base-select` and `select::picker(select)` across `/manage`, playback speed, and subtitle settings with obsidian glass styling and brand red active highlights.
- **Library Navigation Density & Hierarchy:** Removed redundant A-Z sort dropdown across desktop and mobile, and repositioned System Telemetry HUD to the bottom of the home page (strictly after "All Movies"), prioritizing library browsing.
- **Mobile Player Controls Expansion & Dedicated Seekbar Spacing:** Restored primary controls (`↺` Restart, `🔊` Mute, `1×` Speed, `CC ⚙` Subtitles/Settings, Aspect Ratio, Rotate Screen, PiP, Nerd Stats) on mobile inside a swipeable non-overflowing rail, cleanly hid redundant desktop-only buttons (`#volume`, `#shortcutsBtn`, and `-10`/`+10` seek buttons), and eliminated vertical gap between `.seek-time-row` and seekbar (`margin-bottom: -9px !important`).
- **Interactive User Manual & Footer Navigation:** Added in-app User Manual (`/manual`) with full shortcuts cheatsheet, touch gestures, multi-GPU streaming guide, and footer "How to use" link. Authored offline user guide in `docs/MANUAL.md`.
- **Flutter Client Production Player:** Native Android & mobile Flutter client with translucent gradient controls overlay, symmetrical equidistant seekbar spacing (~6dp), dual-time anchor HUD (elapsed time left, total/remaining time right with tap-to-toggle), canonical web button sequence (`↺` Restart, `⏸`/`▶` Play/Pause, `🔊` Mute, `1×` Speed, Audio, Subtitles), vertical-swipe volume/brightness controls (left half = brightness, right half = system media volume, native channels), watch-progress persistence (`PlaybackProgressReporter`), and rapid direct-intent test automation (`--es route "/player"`).
- **Universal Android APK & 10-Foot TV Experience (Fire TV Stick 4K & Android TV):** Single universal APK (`in.anisparvez.media_server_client`) operating seamlessly across mobile phones (touch UI + bottom bar) and Android TV / Fire TV Stick 4K (`AFTMM`) (10-foot D-pad remote UI + collapsible obsidian side rail + borderless fullscreen cinema player). Runtime capability detection (`deviceCapabilitiesProvider`), 2-column details with autofocus action (`autofocus: true`), 2-zone remote transport model (Zone 1 Timeline, Zone 2 Controls), edge traversal bridge (`TvDirectionalFocusAction`), and debounced exit dialog (`TvExitDialog`).
- **Flutter Player Architecture Segregation & Modularization:** Modularized monolithic `player_screen.dart` (2,283 → 1,232 lines, ~46% reduction) into 5 decoupled domain/infrastructure/presentation modules: `tv_player_focus.dart` (`TvPlayerFocusZone`), `player_cast_bar.dart` (`PlayerCastBar`), `player_details_panel.dart` (`PlayerBrandHeader` & `PlayerDetailsPanel`), `player_key_dispatcher.dart` (`PlayerKeyDispatcher`), and `player_media_resolver.dart` (`PlayerMediaResolver`), with 100% backward compatibility and 204+ passing unit/widget tests.
- **Fire TV Stick 4K Hardware Playback Hardening & Driver Lock Prevention:** Resolved low-level MediaTek Display Processor (MDP) kernel fence deadlock and PowerVR GE9215 GPU desynchronization on Amazon Fire TV Stick 4K (`AFTMM`) using `mediacodec-copy`, preventing direct `SurfaceTexture` / `ANativeWindow` fence timeouts on non-16-byte-aligned dimensions (e.g. 1916px) with automatic dynamic software fallback (`fallbackToSoftwareDecoder`, `hwdec: no`) and buffer flush seek.
- **LAN Cast & DLNA Second-Screen Playback:** Cross-platform casting to DLNA TVs (Samsung Tizen, LG webOS) and Google Cast devices (Chromecast with Google TV, Nest Hub). Direct byte-range delivery for DLNA and web-friendly MP4/WebM, HLS for Matroska/HEVC on Chromecast, real-time receiver master volume tracking and 3-state mute toggle, WebVTT subtitle track delivery with live in-cast selector popover, and clean receiver app quit (`cast.quit_app()`) restoring the TV to its home screen upon disconnect.


## 4. Known unresolved issues & active roadmap

### Completed high-priority items

- **Production concurrency tuning & remote streaming benchmarks:** (Completed 2026-10-14)
  Evaluated Waitress WSGI (16 threads, PID 17644) against local origin and Cloudflare named tunnel (`media.anisparvez.in`) across Direct Play, HLS segment streaming, and mixed API workloads (concurrency 1–16). Local aggregate throughput reached **447.88 Mbps** with 100% success; remote throughput capped at **18.43 Mbps** due to physical ISP uplink (~20 Mbps). Waitress memory remained rock-solid at 80–95 MB RSS across all loads. Documented in [`docs/STREAMING_BENCHMARK_REPORT.md`](docs/STREAMING_BENCHMARK_REPORT.md), backed by [`scripts/benchmark_streaming.py`](scripts/benchmark_streaming.py) and JSON artifacts in `tests/load/`.

### Highest priority — immediate work queue

1. **Phase 3 PostgreSQL Migration Preparation:**
   With database backup/restore ([`docs/BACKUP_AND_RESTORE.md`](docs/BACKUP_AND_RESTORE.md)) and concurrency/streaming benchmarks ([`docs/STREAMING_BENCHMARK_REPORT.md`](docs/STREAMING_BENCHMARK_REPORT.md)) complete, proceed to Phase 3: PostgreSQL schema DDL, SQLAlchemy repository mapping, and SQLite-to-PostgreSQL automated data migration tooling.

### Secondary / parked

4. **Automatic OpenSubtitles behavior:** local subtitles work; incorrect automatic OpenSubtitles behavior is parked.
5. **Authentication/access control:** the stable Cloudflare hostname is not authentication. Add access control before wider public sharing.
6. **Cloudflare media-delivery architecture:** review current Cloudflare service-specific video/large-file policies before treating the public tunnel/CDN path as a scalable distribution system.

### Admin authorisation invariants (`app/routes/api.py`)

Routes behind `@require_admin` can **delete the library, purge caches, move originals into the
archive and rewrite the retention policy.** They are reachable from the public internet through
the Cloudflare tunnel. Treat them as the most destructive surface in the application.

- **The Admin PIN fails closed, and has no default.** `get_setting('admin_pin', '')`, never a
  literal. A hard-coded default (there was one: `'6361'`) is not a safe fallback for a secret —
  it makes "no PIN configured" mean "anyone who guesses four digits may delete the library".
  Unset must mean the PIN channel is **closed**, leaving only a Google admin session, which is
  what sets the first PIN deliberately. `/api/admin/status` reports `has_pin` against the same
  empty-string default so the two answers cannot disagree.
- **Never accept the PIN from a query string.** `?pin=` writes the secret into Waitress access
  logs, Cloudflare's edge logs, browser history and `Referer` headers. Header (`X-Admin-Pin`)
  and JSON body only.
- **A closed probe is not a closed door.** Any test asserting the PIN is refused must also
  assert a destructive route returns 403 — see
  `tests/test_admin_auth.py::test_no_configured_pin_means_no_pin_is_accepted`.
- **Do not weaken `is_admin_authorized()` to make a test pass.** The
  `PYTEST_CURRENT_TEST` pass-through is a test seam, not a model for production auth.

## 5. Platform/dependency rules

### Windows
- Windows 10/11 or supported Windows Server.
- Python 3.10+; current tested host uses Python 3.14.3.
- PowerShell, Git, FFmpeg and FFprobe.
- Production WSGI: **Waitress**, not Gunicorn.
- Remote access: `cloudflared.exe` Windows Service.
- Never use `os.kill(pid, 0)` to check process liveness on Windows; use `app.services.transcode_service.is_pid_alive(pid)` (exported in `app`) to avoid broadcasting `CTRL_C_EVENT` across the console group.
- Never use `os.rename()` across disk volumes on Windows; use `shutil.move()` with target collision pre-unlinking.
- In tests and cache audits, always call `get_cache_dir()` rather than referencing `app.config.CACHE_DIR` directly, as test harnesses patch `app.CACHE_DIR`.
- Prioritize the high-capacity secondary drive `D:` (`D:\Flicks`, `D:\Flicks\.archive`, `D:\Flicks\.uploads`, `D:\Flicks\.deleted`) for raw video files, upload staging, cold source retention, and deleted-source staging, preserving the primary fast SSD `E:` (`E:\MediaServer`) headroom for the application, database, active HLS streams, and preview thumbnails. `C:` is not part of this project's storage.
- All media path, cache lookup, and subtitle delivery routines must resolve across `config.get_media_roots()`.
- **Mandatory User Notification on Service Restart**: Whenever backend Python code (`app/*.py`, `app/routes/*.py`, `app/services/*.py`, `app/config.py`, `app/db.py`) is created or edited, the agent MUST explicitly instruct the user to restart the persistent Windows service by running `e:\MediaServer\scripts\restart_service.bat` (or via elevated PowerShell `Restart-Service MediaServer`). Production Waitress caches Python bytecode in memory and does not auto-reload.
- **Verify a deploy by artefact timestamp, never by a health check alone.** After restarting `MediaServer` or `MediaServerRust`, confirm the *binary* is newer than the last source commit before claiming the code is live. A 200 from `/health` proves only that *some* build is running: the service can serve a stale binary perfectly well, and the restart scripts used to fail their build with "Access is denied" and still report success. Concretely: `Get-Item rust\target\release\media-server-api.exe | Select LastWriteTime` and compare against `git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M:%S'`. Compare **full** timestamps including seconds — two comparisons of `HH:mm:ss` alone have silently produced false results here. This is a habit, not a one-off check: do it on every deploy without being asked.
- **Service hosting & resilience (do not regress):** NSSM lives at `C:\MediaServer\bin\nssm.exe` and PostgreSQL binaries at `C:\postgres` (data stays `E:\pgdata`), so both survive `E:` absence; `MediaServerPG` runs as NetworkService with restart-x3 recovery actions. NSSM restarts Flask/Rust within ~5s of a crash. **There is deliberately NO watchdog scheduled task** — it was removed 2026-10-16 (it flashed a console window every 5 minutes); `scripts/install_watchdog.ps1` re-arms it if ever wanted. Accepted gap: recovery actions are finite, so a host that boots without `E:` needs a manual `scripts/restart_service.bat`. **Probe PG with a TCP connect to 127.0.0.1:5432, never `pg_ctl status`** — run by an admin account it cannot open the NetworkService postmaster and reports a healthy cluster as stopped. Repo `.ps1` files must stay pure ASCII (Windows PowerShell 5.1 mangles UTF-8 punctuation into parse errors).

### Linux/Kali
- Python 3.10+; current development uses Python 3.14.x.
- `python3 -m venv`, `pip`, Git.
- FFmpeg and FFprobe on `PATH`.
- Production: Gunicorn/gthread; systemd is recommended.
- Remote access: cloudflared named tunnel.
- Keep origin on `127.0.0.1:8000` when Cloudflare is the public front end.

## 6. Player invariants

- Direct streams must remain isolated from transcoding status/polling logic.
- Seeking must not synchronously assign `currentTime` on every seek-bar drag event; commit on gesture completion.
- During scrubbing or browser seek, `timeupdate` must not snap the slider back to an old timestamp.
- Direct MP4/AAC seeking and MKV/HEVC HLS seeking must both remain functional.
- Preserve player container isolation and mobile viewport clamping.
- `templates/player.html` has a strict single-`<script>` invariant; external scripts must be dynamically injected from the existing script block.
- `/api/media-info` reports the **video stream's end** as `duration` for HLS playback and the container duration for direct play: HLS timelines come from our playlist, while a direct-play browser reads the file's own metadata and must not be desynced. Any HLS completeness denominator (chunks, progress, ENDLIST) must likewise use the video end — a WEBRip whose audio/subtitles outlive the picture otherwise shows an unplayable tail.
- Do not perform broad player rewrites for narrow playback bugs.
- **Modal Dialog Portaling & CSS Transform Isolation:** All modal dialogs, backdrops, and fixed overlay sheets in the web app MUST be portaled to `document.body` via `createPortal(..., document.body)`. Never render `position: fixed` modals inline within deep component trees where parent containers have or can have `transform`, `filter`, `perspective`, or `contain` properties (which trap `position: fixed` containing blocks under the W3C CSS Transforms specification). Page/container animations with `forwards` (such as `fadeIn`) must terminate on `to { opacity: 1; transform: none; }` rather than `transform: translateY(0)`. Overlay backdrops must declare `overflow-y-auto` and modal cards must declare `my-auto` for responsive vertical centering without clipping on short viewports.

### Android / Fire TV Hardware Decoders & Remote Control Invariants

- **Remote Input Takeover Protocol (Strict Invariant):** When taking over inputs or sending ADB remote control key events to a connected Fire TV Stick or Android TV, ALWAYS notify the user beforehand: `"Please do not touch the remote..."`. Once finished interacting or testing, ALWAYS release control by stating: `"The app is free from your control."`.
- **TV Remote Player Back Key Invariant:**
  - When playback is active and player controls are hidden: the 1st Back press (`LogicalKeyboardKey.escape`, `LogicalKeyboardKey.goBack`, or Android system back via `PopScope`) MUST reveal player controls (`_controlsVisible = true`), restore/re-establish player focus to the timeline scrubber (`_tvFocusZone = TvPlayerFocusZone.timeline`), reset the controls auto-hide timer, and consume the event without stopping playback or exiting.
  - When player controls are visible: the 2nd Back press MUST perform normal player exit (cancel auto-hide timers, flush/dispose watch progress, stop player controller, and pop the player route).
  - Never bypass controls visibility with `forceExit: isTv` or immediately pop when controls are hidden.
- **2D Weighted Spatial Focus Traversal (`TvSpatialFocusTraversalPolicy`):**
  - Flutter's default `DirectionalFocusTraversalPolicyMixin` clips candidate widgets to strict 1D geometric bands, which skips visually adjacent focusable elements on D-pad Up/Down when items do not overlap horizontally.
  - Directional focus navigation across the application (registered at `MediaServerApp` root builder and `tvContentFocusScopeProvider`) enforces `TvSpatialFocusTraversalPolicy`: a 2D weighted vector distance policy (`score = Δprimary * 4.0 + Δorthogonal * 1.0 + Δalign * 0.25`) with a 60% row/column overlap gate, guaranteeing intuitive D-pad transitions between cards, rails, and buttons.
- **MediaTek MDP & PowerVR Driver Lock Prevention:** On Android devices with MediaTek MDP and PowerVR GPUs (`AFTMM`), zero-copy `hwdec: mediacodec` causes display fence deadlock (`wait input fence timeout`) when video dimensions are not 16-byte-aligned. Always configure `VideoControllerConfiguration(hwdec: 'mediacodec-copy')` in `MediaKitPlayerAdapter` to copy decoded frames and upload via standard OpenGL ES texture shaders (`vo=gpu`), decoupling decoded frames from direct ANativeWindow hardware composer sync fences.
- **Automatic Dynamic Software Fallback:** `fallbackToSoftwareDecoder()` dynamically sets `hwdec: 'no'` (libavcodec CPU decoding) and flushes decoder buffers with a micro-seek if hardware decoding errors occur or if the first video frame is not rendered within 4 seconds (`_firstFrameRendered` tracking via `videoController.waitUntilFirstFrameRendered`).
- **Broadened Decoder Error Keywords:** The error listener must catch and trigger fallback on keywords: `video`, `codec`, `mediacodec`, `vd`, `decoder`, `hwdec`, and `surface`.

### Cast and DLNA invariants (Rust migration, Phase C4)

Applies to the native Rust cast service as much as to the Python one.

- **An empty HTTP 500 from a DLNA renderer means "I could not fetch that URL."**
  It is a reachability question, not a cast bug, and the empty body gives no
  hint. Two separate layers produced it — `MediaServerRust` binding
  `127.0.0.1`, and a missing Windows Firewall inbound rule for
  `media-server-api.exe` (Flask has one for `python.exe`). Check the listener
  address and the firewall rule before debugging the cast logic. The rule is
  created idempotently by `scripts/install_rust_service.ps1`; it is required for
  the port swap too, where Rust takes `:8000`.
- **A service bound to loopback looks healthy from its own machine.** Every
  probe and health check goes through `127.0.0.1`, so a loopback-only bind is
  invisible to the whole suite *and* to every other device on the network. Rust
  defaults `RUST_HOST` to `0.0.0.0`; Flask already binds `0.0.0.0`.
- **A Cast receiver presents a self-signed X.509 v1 certificate.**
  `rustls-webpki` accepts only v3 and rejects v1 while extracting the public
  key, *before* any custom verifier runs, so no verifier configuration works
  around it. Use the Windows Schannel stack (`native-tls`). Only the trust
  *chain* is bypassed — the handshake signature is still verified, so a passive
  attacker cannot impersonate the receiver. Never connect to a host supplied by
  a request: take it from the discovery cache.
- **Media-namespace messages go to the launched app's `transportId`, which is a
  per-session UUID** — *not* `receiver-0`, and *not* the documented constant
  `urn:x-cast:com.google.cast.media-receiver`. Addressing either is answered
  with `CLOSE` on the connection namespace. The sequence is: `CONNECT` to
  `receiver-0`, `LAUNCH` `CC1AD845`, read the app's `transportId` out of
  `RECEIVER_STATUS`, **`CONNECT` to that transport**, then `LOAD`. Read the id
  from `status.transportId` or `status.applications[].transportId`.
- **`streamType: BUFFERED`, not `LIVE`.** A receiver told the stream is live
  treats the artifact as unseekable.
- **`currentTime` is a top-level member of `LOAD`, a sibling of `media`** — not
  nested inside it. Nested, it is ignored completely: the LOAD succeeds, the
  receiver plays from zero and reports no error, so a resume cast appears to
  work while losing the user's position.
- **`MEDIA_STATUS.status` may be a list, not an object.** Google specifies an
  object; the DU7000 sends `{"status":[{...}]}`, and `[]` while idle. Parsing
  it as an object returns nothing, so a playing cast reads as `unknown` with
  position 0 and no error. Accept both.
- **Cast status is read from the receiver, never from a cached push.** Receivers
  emit `MEDIA_STATUS` on transitions only — measured minutes apart while
  playing. A receiver in standby reports **no volume field**; the default must
  be 100, because inventing 0 tells the user their television is muted.
- **A media-namespace message needs a running session.** Launch the default
  media receiver (`CC1AD845`) and confirm it is running *before* `LOAD`;
  otherwise the receiver answers with `CLOSE` on the connection namespace. The
  running app is reported as `status.appId` on some receivers and under
  `status.applications[]` on others — check both. And `LAUNCH_STATUS:
  USER_ALLOWED` is not the same as "the app is up": both replies arrive seconds
  later, so sequence on a poll, not on the ack.
- **A receiver may `PING` us and expects `PONG`.** Unanswered, it tears the
  virtual connection down, which surfaces as a `CLOSE` mid-request.
- **Never cache a Cast connection without a liveness path.** A receiver resets
  the socket on its own, and a cached dead socket fails every later command
  identically — so a playing cast becomes permanently uncontrollable, and
  `stop` cannot be delivered at all. Every action must redial and retry once.
  Redial must re-run the whole app session (launch, read `transportId`,
  `CONNECT`), because the transport id is per-session; reusing a stale one is
  what produces the original `CLOSE`.
- **`stop` must quit the app, not just stop playback**, or the TV is left on an
  idle blank receiver screen that reads as a hang.
- **A cast scan replaces the device map**, so connections are cached per device
  and survive a scan. mDNS/ARP windows miss a device in roughly one scan in
  three; a visibly running cast must stay controllable.
- **Verify receiver CORS on `/media/` and `/hls/` only.** A receiver is a web
  runtime: it fetches the manifest and every segment cross-origin. Without
  those headers it downloads the playlist, requests **no segment**, and the
  session ends with no error this server can see. `/api/*` must stay
  unreadable from another origin.

### DLNA rendering (Samsung TVs and other UPnP renderers)

- **Seekability is advertised, not implemented.** A renderer decides whether its own FF/prev buttons
  are usable from metadata it reads *before* playback: the DIDL `res` `protocolInfo` **4th field** and
  the `contentFeatures.dlna.org` header on the media response. `cast_service.DLNA_CONTENT_FEATURES`
  (`DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000`, the minidlna value)
  is the single source of truth for both; `http-get:*:<mime>:*` means "no DLNA operations" and leaves
  the Samsung DU7000's FF/prev greyed out even though byte-range serving works. `routes/media.py`
  imports the constant and adds `transferMode.dlna.org: Streaming` to every `/media` response — DLNA
  headers are additive, browsers and the app keep using plain bytes.
- `dlna_load()` sends `size`/`duration` as DIDL `res` attributes (`duration` as `H:MM:SS.mmm`), both
  best-effort: a failed probe omits the attribute, never the cast.
- **New DIDL metadata only counts once the renderer re-loads the media** — a TV keeps the capability it
  saw at `SetAVTransportURI` time, so re-cast after changing the protocolInfo before judging.
- `/media` answers `TimeSeekRange.dlna.org: npt=SECONDS-` (a *time* range) by converting it to the
  keyframe byte offset at or before that time (`ffprobe -v error -select_streams v:0
  -read_intervals <t>%+#1 -show_entries packet=pos,pts_time:format=duration -of json`, memoised by
  path+mtime+seconds) and serving a 206 through `werkzeug.utils.send_file(path, environ)` with a
  synthetic `HTTP_RANGE` — flask's `send_file` takes no `environ`. The reply states what was served:
  `TimeSeekRange.dlna.org: npt=<start>-<duration>/<duration>`. **`Range` always wins**: time seeking
  engages only when `TimeSeekRange` is present and `Range` is absent.
- A time seek to ≤0 s resolves to **byte 0**, not the first video packet: a plain MP4 keeps its `moov`
  box ahead of `mdat`, so a first-packet start hands the renderer an undecodable stream. When neither a
  keyframe offset nor a duration can be established, answer the plain 200 — a `TimeSeekRange` reply
  must not guess the range it served.
- Seek support is per-request, not per-model: the DU7000 applied a resume `Seek` (REL_TIME) on a fresh
  load (TV reported the resumed position) while the same model answered UPnP 701 to remote seeks.

### Google Cast (phone casting to a TV)

- **A Cast receiver is a remote, not a mirror: whoever sent LOAD owns playback.** `cast_load()` must put
  the start position in the LOAD message (`play_media(..., current_time=position)`) and must declare
  `stream_type='BUFFERED'`. pychromecast defaults `stream_type` to `LIVE`, which tells the receiver the
  artifact is not seekable, and a `Seek` sent after a load races the receiver's media session — the
  Samsung DU7000 answered "Failed to execute seek 180.0" and then played from 0. That is the whole of
  "it always starts from the beginning / the TV ignores seeks".
- **Control commands wait (bounded) for the media session** (`_wait_for_cast_session`, 4 s): a command
  sent into the LOAD→session gap is rejected. `stop` never waits — it is the way out of a stuck cast.
- **While `isCasting`, the phone's transport controls belong to the TV.** The local player is
  deliberately paused for the whole cast, so a control wired only to it looks broken ("play/pause on the
  phone does nothing on the casted video"). In `player_screen.dart` the play/pause button, the scrub bar,
  restart and double-tap skip all forward via `sendControl('play'|'pause'|'seek')`, and the controls read
  their position/duration/state from the cast — not from the paused local player. `CastController`
  applies a seek optimistically so the bar tracks the finger between the 5 s status polls.
- **Read the status on demand; do not trust the cached push.** A receiver sends `MEDIA_STATUS` on
  transitions only (measured minutes apart while playing), so `cast_status()` calls
  `update_status(callback_function=…)` and waits ≤2 s for the answer before reading
  `controller.status` — without it the phone's cast bar froze on a position from minutes ago and a stale
  read could look like a command that never landed.
- **A device a scan missed is still controllable while its connection is open.** Discovery *replaces*
  the registry map and an mDNS browse window misses the DU7000 in roughly one scan of three; every
  control/status call then answered "Unknown device - rescan and try again." while the phone was visibly
  casting to that TV. `CastRegistry.resolve_device()` falls back to a cached connection (and `play`,
  `control`, `status` all use it); a device with neither a scan entry nor a connection is still unknown.
- **Chromecast takes only direct containers; anything else needs an HLS cache first** — the cast bar's
  error text is the only sign when it is missing.
- **Anything a receiver fetches *itself* must be served with CORS.** A receiver is a web runtime (CAF),
  and its HLS loader fetches the manifest and every segment cross-origin: without
  `Access-Control-Allow-Origin` on `/hls/*` the TV downloads the playlist, asks for **no segment**, and
  the session ends at `stopped` with no error this server can see — measured, and the whole of "MP4
  casts, MKV does not" (a media element is not a CORS request, so direct play never hit it).
  `routes/media.py` owns `CORS_HEADERS`/`CORS_PATHS` and applies them in an `after_request` to `/media/`
  and `/hls/` only — `/api/*` is deliberately outside the scope. A loader that sends `Range` preflights
  (`Range` is not a safelisted header), so OPTIONS is covered; `tests/test_media_cors.py` pins all of it,
  including that every URL `build_media_url()` hands a receiver lives on a CORS path.
- Cast status is read from the receiver (`/api/cast/status` → `state`, `position`, `duration`, `volume`, `muted`), so it is
  the ground truth for "did the TV actually move?" — never infer it from the phone's UI.
- **Cast Disconnect Quits Receiver App:** Disconnecting from Google Cast MUST invoke `cast.quit_app()` (`socket_client.receiver_controller.stop_app()`), `cast.disconnect()`, and connection cache eviction. Halting playback alone leaves the default media receiver running as an idle blank screen on the TV.
- **Cast Master Volume & Anti-Reset Synchronization:** Cast status endpoints must query and report actual receiver volume (`volume_level * 100` and `volume_muted`), and remote UI sliders must enforce scrub isolation (`scrubVolume`) and progressive red track fills.
- **Cast Subtitles Require Full LAN URLs:** Cast receivers cannot fetch relative paths (`/subtitles/...`). Tracks in `media_info['tracks']` must use fully-qualified LAN origins with WebVTT mimetype and high-contrast styles, and expose live in-cast switching (`action == 'subtitle'`).

### HLS cache integrity (learned the hard way)

- **Segment indices are strided per chunk (`SEGMENTS_PER_CHUNK_STRIDE = 32`), and that is what
  keeps chunks from overwriting each other.** A 60 s chunk does **not** reliably emit the 15
  segments the plan expects: with the AMF encoders it emits 15, 16 or 17 depending on
  source/GPU/driver (the Vega 8 and RX 560X even disagree - pinning `-g` to a 4 s GOP makes the
  RX 560X emit a *single* 60 s segment, so no encoder-side setting fixes this). Under the old
  dense grid (`start_seg = round(start/4)`) an extra segment landed on the **next** chunk's first
  index, and whichever render finished last won - destroying ~1.25 s of the previous chunk's tail
  at **every** overflowing boundary. Live proof: of 10 caches, the nine whose chunks emitted
  exactly 15 segments have 0 packet gaps, while Spider-Man - the only cache with overflowing
  chunks (16 x70, 17 x15) - has exactly **85 gaps**, matching its 85 overflowing chunks.
  Consequences for anything that touches segments:
  - Never walk segment indices densely from 0 (`while segment_{idx}.ts exists`): it stops at the
    first inter-chunk gap and silently drops every later chunk (coverage read 50 % for a fully
    rendered 120 s source). Glob and sort instead, and bound a chunk's run by
    `start_seg + SEGMENTS_PER_CHUNK_STRIDE`.
  - Frame accounting must measure a chunk's **own run** of segments, not a fixed 15: measuring
    only the planned count made complete chunks look 1.25 s short.
  - A cache built on the old dense grid cannot be migrated in place (the indices *are* the
    ordering): `_prepare_cache_layout` clears an unmarked cache and re-renders it on the strided
    grid, marking the directory with `.seg_layout` = `stride32`.
  - `-force_key_frames` does not make the AMF encoders obey the plan, and `-g` changes the segment
    count rather than controlling it. Treat the segment count as unknown; the layout must
    tolerate it.

- **`#EXTINF` labels are honest - do not "correct" them.** A segment labelled 2.4 s really holds
  60 frames = 2.4 s of video at 25 fps. The trap is `ffprobe -show_entries format=duration` on a
  segment: the container duration includes the **audio pre-roll** (measured 4.33 s container vs
  2.4 s video for the same segment). Rewriting labels from that quantity overstates the video
  timeline and **hides real content loss** - it is how a 99.88 % "repair" once masked 277 s of
  missing frames. Never relabel a playlist from container durations.
- **`#EXT-X-TARGETDURATION` must cover the longest segment, and it is derived from the labels.**
  RFC 8216 forbids a segment longer than the declared target, and the AMF encoders never kept the
  planned 4 s cadence: the eight live caches held 5.0 s segments while declaring 4. `honest_target_duration()`
  (`transcode_service`) raises the declaration to `ceil(longest #EXTINF)`; the master rebuild, the layout
  migration and the resume rebuild all call it, and `hls_playlist` corrects what it *serves* — so caches
  written before the fix are healed on delivery while the file on disk stays as written (its labels are
  the content record). Same rule as the EXTINF lesson above: labels are honest, container durations not.
- **Frame accounting is frame-index exact, and shared with the audit tool.** `chunk_content_deficits()`
  and `scripts/hls_frame_audit.py` call the *same* helpers in `chunk_transcode_service`:
  `frame_index_at()`, `expected_frames_for_window()`, `chunk_boundary_frame_tolerance()` and
  `aggregate_loss_ceiling_frames()`. Never reintroduce a local expectation or window in either place.
  - **Expectation is a difference of frame indices, never `duration * fps`.** `duration * fps` is
    fractional at 23.976 / 29.97 / 30000÷1001, so a complete chunk measures short and every boundary
    contributes a phantom deficit.
  - **Per-chunk tolerance is a frame count, never a percentage of duration.**
    `chunk_boundary_frame_tolerance(fps)` is a fixed 0.7 s of alignment slack expressed in frames. The old
    `max(0.6s, 1% of chunk)` gave a 60 s chunk 0.6 s and a 2 h feature 72 s, so identical damage was
    judged by whichever window it landed in.
  - **The 0.7 s is measured, not chosen.** A single fresh render of a 4K HDR/AMF chunk reproducibly loses
    exactly **15 frames (0.625 s @ 24 fps) at the head of the window**, and the loss is **identical for
    60 s, 61 s and 65 s windows** — fixed decode-pipeline priming, *not* a seek-position error. Seeking
    1 s earlier and extending `-t` by 1 s recovers it (1440 → 1449 frames). Repeated repair passes converge
    it away, which is why the serial repair loop eventually stopped; do not "fix" it by changing the render
    command without weighing that against a live transcode pipeline.
  - **Measure a chunk's own contiguous run**, bounded by `start_seg + SEGMENTS_PER_CHUNK_STRIDE`. A chunk
    legitimately emits 15, 16 or 17 segments; counting only `expected_segs` undercounts and invents
    deficits up to **104 601 frames** where none exist.
  - **Per-chunk allowances multiply, so there is a whole-cache ceiling.** 17 frames × 157 chunks is ~111 s
    a feature could shed unnoticed. `aggregate_loss_ceiling_frames()` = `max(10 s, 0.1 % of runtime)`, applied
    to **both** the strided and the dense path so both layouts are judged by one standard. It fires
    **only when no chunk was flagged** — its purpose is the case the per-chunk check cannot see.
  - **Unknown is never empty.** A frame count of `-1` means unmeasurable and the chunk is skipped; only a
    genuinely-read 0 counts as zero. Returning 0 for an unreadable segment caused unbounded re-rendering.
    **This bit twice more inside `measure_segment_frame_count`, and both are now fixed:** the freshness
    guard that refuses to probe a segment younger than `_SEGMENT_PROBE_FRESH_SECONDS` returned `0`, not
    `-1`, so a chunk re-rendered by the serial repair measured its own brand-new segments as empty, was
    reported as ~15s short, and had its ENDLIST refused — after which the repair re-rendered a chunk
    that was never short. Cost was roughly **half the elapsed time** on every affected transcode (26.2s
    -> 13.7s on a fixed 96s clip). The `no ffprobe` branch had the same defect. Any new early return in
    that function must be `-1`.
  - **Never walk segment indices densely from 0** — not for accounting, and **not for counting what a
    resumed cache already holds.** `chunk_transcode_service.py` computed `_initial_cached_sec` with
    `while (hls_dir / f"segment_{i:06d}.ts").is_file(): i += 1`, which stops at the first inter-chunk
    gap on the strided layout: a resumed cache holding 2447s reported 60s. "Newly encoded" then became
    the entire cache and the UI reported **16.84x on a job actually running near 2x**. Glob and count.
  - **`_finalize()` records the accepted shortfall** to `hls.loss.json` (frames, seconds, chunks, both
    thresholds, timestamp, reason) when it seals a short cache. Not into `hls.progress` — that is ffmpeg's
    own `-progress` file.
  - **That record was silently never written until 2026-10-11.** `_record_accepted_loss()` called
    `chunk_content_deficits` with **no import in its scope**, while its three sibling call sites each do
    a function-local one (a module-level import would be circular — `transcode_service` imports from
    `chunk_transcode_service`). The `NameError` was absorbed by the blanket `except` at `debug`.
    **So "no `hls.loss.json`" is not by itself evidence that a cache is clean** — a broken recorder
    produces the same absence, which is how this hid. Frame counts are the load-bearing measure.
    `tests/test_accepted_loss_record.py` pins that the record appears with every documented field, that a
    clean cache still writes nothing, and that the name resolves with no swallowed error. The blanket
    `except` stays (accounting must never block sealing), so a future typo would still fail quietly:
    in this area, assert on the **file**, never on the absence of an exception.
- **Never call `source_video_duration(path, fallback=<anything but None>)`.** Any non-`None` fallback
  disables that function's own container-duration fallback, so a title whose video end cannot be measured
  returns a hard `0`; `plan_chunks(0)` is then `[]` and the cache is judged **vacuously complete**. Use the
  bare call. This silently skipped 28 Weeks Later in `hls_restore_endlist.py`, and every such title in
  `hls_frame_audit.py`.
- **A planned chunk window must be able to hold a frame.** `plan_chunks` drops any final window shorter
  than `MIN_PLANNABLE_CHUNK_SECONDS` (`1e-3`) instead of emitting it. The threshold is
  **zero-frames-at-any-rate**, not a round number: `plan_chunks` has no frame rate, but at the highest
  plausible rate (120fps) one frame lasts 8.3ms, so any window under ~1ms holds zero frames at every
  rate and is unrenderable by construction. **Do not raise it toward a rounder value** — `0.5s` would
  silently discard half a second of real video from the tail of every source that has one. The residue
  is not lost: it is absorbed into the final *genuine* chunk's `duration`, so coverage stays exact.
  - Why it matters: `expected_segs` is `max(1, round(dur/4))`, so a ~1e-13s window still **claimed one
    segment**. No render could satisfy it, `_chunk_output_ok` failed, and the caller **retired the GPU
    worker for the job** — a cascade at the very end of an otherwise healthy run, after all real work
    was done. Symptom: ENDLIST written and zero deficits, alongside alarming
    `GPU worker ... retiring it for this job` lines. Worst case the last chunk cannot be produced by any
    healthy worker and the job aborts. The residue is float drift on a duration that divides exactly
    (`600.0000000000002`), and the degenerate window is **always the last one**.
  - **Dropping it cannot shift a segment index**, and this is asserted rather than assumed:
    `start_seg = chunk_id * SEGMENTS_PER_CHUNK_STRIDE`, so ending the loop leaves ids contiguous
    `0..N-1` and changes no existing chunk's range. An off-by-one here would corrupt the strided
    layout — the cause of real past data loss — so `tests/test_chunk_tail_chunk.py` pins structural
    identity against the clean duration across a residue sweep. `_chunk_output_ok` also carries a
    companion guard (judge nothing for a zero-frame window) so a degenerate chunk reaching the check by
    another route cannot retire a worker; that companion is **not** the fix, `plan_chunks` is, because
    the defect is upstream.
- **`_finalize()` only runs at the end of a transcode job**, so a cache refused ENDLIST is never
  re-evaluated on its own — it simply sits there. `scripts/hls_restore_endlist.py` re-checks and seals such
  caches using the fixed measurement (restoring only what measures complete, backing up the playlist
  first). Run it after any change to the accounting.
- **Frame accounting is the only trustworthy content measure.** `chunk_content_deficits()`
  counts video packets per chunk and compares with `chunk window x source fps`; a real cache
  measured 100 % by duration while missing **277.2 s of frames across 101 chunks** (independent
  packet-PTS scan: 85 gaps / 279.4 s - the two agree within 2 s). A frame count of `-1` means
  *unknown* (unreadable file, no ffprobe, segment still being written) and must never be treated
  as empty, or every chunk looks deficient and the cache re-renders forever.
- **ENDLIST must not be written over measured content loss**, and a chunk beyond its boundary allowance
  is not "rendered". The practical rule is bounded: a chunk may fall short by up to one **chunk-boundary
  allowance** (measured encoder priming — see the frame-accounting section below) and a whole cache by up
  to the **aggregate ceiling**; past either, ENDLIST is refused. `repair_understated_caches()`
  (cache-maintenance-worker) strips ENDLIST from caches that claim completion but are short, so the
  pipeline re-renders them. It never relabels: a genuinely short cache must be re-rendered, not
  rewritten. The accepted shortfall is **recorded** to `hls.loss.json`, not silently swallowed.
- **`_is_hls_truly_complete()` is a predicate and must never write.** Its only input is
  `cumulative / source_duration`, which is label arithmetic - the exact measure recorded above
  as having masked 277.2s of missing frames across 101 chunks. Appending `#EXT-X-ENDLIST`
  there would seal precisely the frame-deficient caches the frame accounting exists to catch,
  and did so from a 1Hz progress callback, unserialised and non-atomically, violating the
  `_PLAYLIST_WRITE_LOCK` + `write_text_atomic` rule below. Sealing a verified-complete cache is
  `scripts/hls_restore_endlist.py`, which re-checks with frame counting. **A function named
  `is_*complete` has no business mutating the thing it is judging.**
- **Frame measurement must respect the cache's layout.** Per-chunk windows are exact *only* on the
  strided grid (`.seg_layout` = `stride32`). On a legacy dense cache chunk N's overflow segment
  sits on chunk N+1's first index, so a strided window reads a neighbour's segments for most
  chunks and a near-empty tail for the last ones - that is how three complete caches were
  reported as missing 38.5 s / 24.2 s / 13.7 s and had their ENDLIST stripped. `chunk_content_deficits()`
  therefore dispatches on `cache_uses_strided_layout()` and judges a dense cache on its
  whole-cache frame total (one aggregate entry, `chunk_id` -1).
- **Duplicate-job detection must not rely on `/proc`.** `find_ffmpeg_info_for_path()` originally
  scanned `/proc/[0-9]*/cmdline` only, so on Windows it returned `(None, None)` on every call and
  the guard in `ensure_hls_transcode()` never fired: the auto-transcoder started a second job on a
  cache another job was already rendering (two jobs, same segment indices). It now enumerates
  processes with `psutil` first and falls back to `/proc`. Caveat: a *user* process cannot read a
  *LocalSystem* process's command line (Windows access control), so the service can detect
  externally started encoders but not the reverse. `ensure_hls_transcode(filename, force=True)`
  skips the completeness gate and is only for a *measured* frame deficit.
- **Stripping ENDLIST is not a heal on its own - the re-render must be queued with it.**
  `_is_hls_truly_complete()` is label-based, and a frame-deficient cache's labels can still sum to
  100 %, so the auto-transcoder called such a cache complete and never touched it (the state
  Spider-Man sat in at 99.88 %). `repair_understated_caches()` calls `ensure_hls_transcode()` for
  every cache with a real deficit, including one already stripped by an earlier pass.
- **Resume from the label sum, never from container durations.** `_hls_resume_point()` resumes at
  the content the existing segments hold; resuming from inflated container durations skips
  content that still has to be produced.
- **Packet-PTS jumps at chunk boundaries are expected** (`#EXT-X-DISCONTINUITY` is declared
  there): `chunk_content_holes()` is diagnostic only and must never gate anything.
- **The chunk command itself is frame-complete** - verified with the exact job command shape,
  with/without `-c:a copy`, with/without `-output_ts_offset`, and with two chunks encoding
  concurrently on both GPUs (1500/1500 frames every time). A deficient cache is therefore legacy
  (older code or interrupted runs) and is healed by re-rendering, not by relabelling.
- **All segment measurement is memoised by (path, size, mtime)** and files younger than 3 s are
  skipped. The 1 Hz progress updater rebuilds the master playlist; an unmemoised probe there
  spawned ~1 ffprobe per chunk boundary per second for the whole run.
- **Playlist writes are serialised and atomic** (`_PLAYLIST_WRITE_LOCK`, `write_text_atomic`):
  a torn read is what `_hls_resume_point` then freezes into both `playlist.m3u8` and its `.bak`.
- Completeness decisions divide by `source_video_duration()` (the video-stream end), never the
  container duration: a WEB-DL container can run minutes past the last video frame and would mark
  a finished cache incomplete forever.
- Verification tools: `scripts/hls_content_gap_inventory.py` (label-independent packet audit of
  every cache), `scripts/hls_frame_audit.py` (per-chunk frame accounting), `scripts/hls_gop_matrix.py`
  (real dual-GPU pipeline over synthetic keyframe cadences), `scripts/final_verification_battery.py`,
  `scripts/snapshot_live_data.py`.

### Transcode strategy and telemetry

Full write-up, with the measurements behind every number: `docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md`.

- **`vpp_amf` is a depth converter first and a scaler second.** For a 10-bit source it is the only
  thing that converts to 8-bit, because `h264_amf` **rejects 10-bit input on this host** — measured on
  *both* adapters (`exit=-1313558101`, `10-bit encoder is not supported`), and the driver is current
  (`31.0.21923.1000`, June 2025). Do not read ffmpeg's "drivers versions lower than 23.30" text as
  "update the driver": it is checked against the AMF runtime, and H.264 High10 is not available on this
  VCN hardware regardless of driver age. The encode fails outright rather than degrading.
  For an 8-bit source no taller than the 1080p profile, `vpp_amf` performs no
  resize and no conversion at all — a full GPU round-trip for nothing. `select_amf_strategy()` picks per source and
  **fails safe: an unprobed source always keeps `vpp_amf`**, because guessing "no resize needed" from
  missing data is the one mistake that would silently emit a wrong stream.
- **`scale_d3d11` / `scale_d3d12` are not a substitute on this hardware.** Both fail with
  `Could not create the texture (80070057)` — the driver will not create a texture from `p010le` on
  these cards. Do not re-test them without a driver change.
- **More workers must never cost content.** The acceptance criterion for any worker-count change is a
  finished transcode with **zero missing frames**, ENDLIST written and no `hls.loss.json`; throughput is
  reported alongside, but a faster render that drops content is worthless. Measured on a 600s clip:
  2→4.55x, 3→5.16x, **4→5.26x**, 6→5.05x — all four PASS, and every run produced **byte-identical
  output layout** (151 segments, index 0..320, 170 inter-chunk gaps). Worker count changes speed, not
  content. A *negative* missing-frame count is a rounding surplus at a chunk boundary, not a failure —
  the criterion is `missing_frames <= 0`, never `== 0`.
- **Duplicated GPU workers need distinct names.** The scheduler retires a GPU for a whole job *by
  name*, so shared names would take down every duplicate of that adapter at once and defeat the
  fallback path.
- **Gated behind `MEDIA_SERVER_TRANSCODE_STRATEGY`, default `legacy`.** Set `adaptive`, plus
  `MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10=4` (measured optimum) and
  `MEDIA_SERVER_TRANSCODE_WORKERS_8BIT=2`, to engage. The deployed pipeline is unchanged until then.
- **A progress number is a rate over a stated window, not a lifetime average.** `hls.progress` now
  carries `rate_window_s` and `eta_s`; the job owns the ETA because it is the only thing that knows both
  the current rate and how much was already cached when it resumed. Consumers must not re-derive an ETA
  from a rate alone.
- **Withhold the number when the window is too short to mean anything** (`MIN_RATE_WINDOW_S = 20`). The
  UI shows "Calculating..." instead of a confident wrong figure. This is not polish: a two-sample rate
  over half a second is how the UI came to claim 5.3x with a 7m53s ETA on a job really averaging
  ~2.2x with ~16 minutes left.
- **Never benchmark this pipeline while another transcode is running**, and never accept a wall-clock
  number without confirming the run completed — a failed ffmpeg invocation exits in under a second and
  reads as a very fast encode. Verify with `-progress` (`progress=end` plus a final `frame=`) or a frame
  count. A contention artifact is what produced the false conclusion "CPU beats the GPU" here.

## 7. Testing protocol

Before committing:

```powershell
python -m py_compile app/config.py app/services/transcode_service.py app/services/chunk_transcode_service.py app/services/gpu_service.py
.\venv\Scripts\python.exe -m pytest tests/
```

Flutter client:

```powershell
.\scripts\run_flutter_tests.ps1
```

- **Run the Flutter suite through `scripts/run_flutter_tests.ps1`, never as a bare `flutter test`.** It purges media_kit's orphaned temp state before the run and again in a `finally`, which is what stops the accumulation. `NativeReferenceHolder` writes one reference-buffer address to `...NativeReferenceHolder.$pid`, creates that file empty before writing, and never deletes it; Windows recycles PIDs, so a new test process inherits a dead run's file and either `int.parse('')`s it (`FormatException: Invalid number`) or adopts a dead heap pointer via `Pointer.fromAddress`, hanging every `add()`/`remove()` that awaits the never-completed `_completer` — the whole file then reports "did not complete". Measured: 415 orphaned files (70 empty) spanning 2026-09-24..10-03 caused 2 failures in 6 runs *including one `--concurrency=1` run*, so serial is **not** a fix; after the purge, repeated full runs leave 0 stale files. The script also refuses to delete a file whose PID is a live process. Debug-mode only (`if (!kDebugMode) return;`), so release APKs and device playback are unaffected. Full analysis, and the rule not to re-add `MediaKit.ensureInitialized()` to tests that do not need native playback, are in `docs/FLUTTER_CLIENT_STATUS.md`.
- **Ordinary Flutter tests must never reach the live server.** `test/support/test_network_guard.dart` installs an allowlist `HttpOverrides` (per-isolate, so call it from each file's `setUp`/`setUpAll`, after `TestWidgetsFlutterBinding.ensureInitialized()`) that refuses any non-sentinel host, plus a shared sentinel origin `http://test.invalid:8000` — deliberately non-loopback, because `PlayerMediaResolver.resolveServerOrigin` skips loopback media hosts and would then fall through to the production `connectionControllerProvider`. Tests that genuinely need the running server stay behind `liveServerSkip` (`MEDIA_SERVER_LIVE_TESTS=1`) and must never null `HttpOverrides.global` unconditionally.

Cache-directory safety when running the suite on the live host:
- **Never resolve `conftest` by module name.** `tests/conftest.py` and `tests/integration/conftest.py`
  share a basename and neither directory has `__init__.py`, so pytest registers **both** under the
  module name `conftest` in `sys.modules`, and whichever is imported last wins. `_write_guard` looked
  its production-path set up as `sys.modules["conftest"]._PRODUCTION_PATHS`, got a module that has no
  such attribute, and **silently fell back to its own set** — so every path added through
  `temporary_production_paths()` was invisible to the guard and 18 refusal tests failed with
  `DID NOT RAISE RuntimeError` while the guard was installed, working, and correctly classifying
  `D:/Flicks`. The owner now hands the set over explicitly
  (`_write_guard.set_production_paths(_PRODUCTION_PATHS)` at `pytest_sessionstart`), holding a **live
  reference, not a copy**, so temporary additions stay visible. If you need conftest's data in a test,
  import it as a fixture — never as a module.
- **A test module must not configure the environment at import time.** `test_app.py` used to create its
  own `TemporaryDirectory`, set `MEDIA_SERVER_MEDIA_ROOT` to it, and then `import app` — which only
  works if that file is the *first* module to import `app`. `test_api_contracts.py` sorts earlier and
  imports `app` first, so `config.MEDIA_ROOT` was already bound to conftest's root, the later import was
  a no-op, the fixtures landed in a directory nothing pointed at, and **36 tests failed with 404s** while
  the same file passed 58/58 alone. It now uses the root the app is already pointed at. **Import order
  must never decide where a test writes.**
- When you change isolation, verify it the hard way rather than trusting a green run: snapshot the
  library file list, the production `movies` rows and the `cache/hls` directory list (plus a hash of
  each) before and after a full run — all three must be unchanged.
- `tests/conftest.py` owns test isolation: it redirects the cache, database, upload target/staging, archive and deleted directories onto a throwaway tree **through the environment before the app is imported** (so a `config` reload recomputes throwaway paths), re-asserts them before every test, and refuses any deletion inside the checkout's `cache/` tree. Never rely on import-time attribute rebinding alone: `tests/test_app.py`'s teardown reloads `app.config` and `tests/test_selenium_multi_seek_coyote.py` rebinds `app.CACHE_DIR = app.config.CACHE_DIR` — that is how a full-suite run once deleted the live transcode cache. `audit_orphaned_caches()` derives the "active" set from `video_paths()`, so any run whose cache is not isolated makes every real HLS directory look orphaned and the non-dry-run purge deletes production transcodes; likewise, `_resolve_upload_dirs()` returns `MEDIA_ROOT` under pytest, which once wrote 22-byte fixtures into the real library and fixture rows into the production database.
- The orphan audit is fail-closed by design; do not reintroduce bare `except Exception: <empty active set>` handling around media enumeration.
- **A live purge deletes every cache directory under the active root that no enumerated media maps to — so a test that calls `purge_orphaned_caches(dry_run=False)` must own a dedicated cache root.** `CachePurgeSafetyTests` used to take the shared session cache root from `get_cache_dir()`, so its four live purges could remove directories belonging to *other* tests. Measured: a directory planted in the shared root by an unrelated test was destroyed by those purges **while the whole suite stayed green**, because the planted directory's owner had no assertion about its own survival. A green suite is exactly what hid this.
  - Isolation belongs in **`setUp`**, not at import time: conftest's `_point_app_at_temp()` re-imposes the shared session cache before EVERY test, so a module-level `app.CACHE_DIR = ...` is already overwritten before any test body runs. `tests/test_storage_retention.py` now establishes it in `setUp` via `_dedicated_cache_root()` and validates with `_assert_dedicated_cache_root()` **before** pointing the app at it and **before** any purge-capable call, then restores in `tearDown` and removes the tree.
  - `tests/test_cache_purge_isolation.py` pins the blast radius by snapshotting the shared root around the whole class and asserting it is byte-identical — not by planting one directory, which would miss a purge that removes several.
- **Pre-existing leak, same file:** `test_audit_and_purge_orphaned_caches` creates a dedicated root with no matching cleanup — 40 `mscache_purge_orphans_*` trees had accumulated in `%TEMP%`. Cosmetic (all under temp), but it accumulates every run. Not fixed; noted rather than silently widened.
- `purge_orphaned_caches()` refuses to run when the audit reports itself degraded, and skips any directory holding `hls.progress`/`playlist.m3u8`/`chunk_*.m3u8*` written within `RECENT_CACHE_GRACE_SECONDS` (live transcode). Startup no longer purges orphans unless `MEDIA_SERVER_PURGE_ON_STARTUP=1`.
- Never fall back to a bare `MEDIA_ROOT / user_input` join when `safe_path()` refuses a name, and never unlink without an `_is_within_media_roots()` check: the service runs as LocalSystem, so a traversal name in `/api/media/delete` deletes arbitrary host files (see `docs/PROJECT_STATUS.md`). Audit sibling deletion paths the same way.

Verify at minimum:
- Direct MP4/AAC playback.
- MKV/HEVC HLS playback.
- Seek to `0:00` and arbitrary positions.
- Seek-bar hover displays frame preview thumbnails.
- System Telemetry HUD reports active GPU engine load.
- Subtitles remain correctly positioned.
- No mobile horizontal/vertical layout regression.

### Frontend API client invariants (`web/src/lib/`)

- **Every request has a deadline.** `request()` owns one `AbortController` covering both
  caller cancellation and a timeout, and the socket is actually released when the deadline
  fires — not merely abandoned. Without it a hung fetch and a slow one are indistinguishable:
  the viewer gets an indefinite skeleton, no error, and no recovery short of a reload. This is
  not hypothetical; `/api/movie/{filename}` was observed exceeding 30s during a service restart.
- **Budgets are measured, not guessed.** Cold `/api/movie/` costs 2.5–8s because the route
  probes the file server-side, so `DEFAULT_TIMEOUT_MS` is 20s and the media-probing endpoints
  get `MEDIA_PROBE_TIMEOUT_MS` (45s). Ten simultaneous cold details requests finish in ~3.5s
  wall. Re-measure before changing either number — a deadline below the real cold path fails
  the slowest titles *deterministically*.
- **A deadline reports as `ApiTimeoutError`, never as an abort.** Check `timedOut` before
  rethrowing, or the platform's opaque "The operation was aborted" hides the cause. Equally, a
  *caller* abort must stay an `AbortError`: reported as a timeout, every route change away
  from a slow page would flash a spurious "server took too long" on the way out.
- **A failed load is never terminal.** `useAsync` exposes `reload()` and `StateMessage` renders
  a retry. When you add a screen, wire `onRetry` — do not leave the viewer needing a page reload
  to recover from a dropped connection.
- **Never hard-code a duration in a test's mock.** A `fetch` mock that never settles *and never
  rejects on abort* leaves `await fetch()` pending after a timeout, so the deadline test hangs
  instead of failing — the one outcome indistinguishable from a broken timeout. Mock the abort.

### Frontend migration: the Android client must not break

The shipped Flutter app (`flutter_client/`) is a **working, not-yet-migrated consumer** and
must keep working throughout the Jinja -> React migration. Two facts make this safe to hold
onto, and both are verified rather than assumed:

- **It requests no HTML page.** It has no `WebView` (zero matches for `webview` in `lib/`),
  and its `AppRoutes` constants (`/home`, `/library`, `/player`, `/movie-details`,
  `/connection`, `/settings`) are `GoRoute` definitions for in-app navigation, never
  server URLs. Its entire server surface is `/api/*`, `/media/`, `/hls/`, `/subtitles/`,
  `/poster/*`, `/tmdb-poster/`, `/tmdb-backdrop/`.
- **Therefore template work cannot affect it**, and `/api/*` must not change shape while
  the app is un-migrated.

Verify after any API or routing change:

```powershell
python scripts/probe_android_api.py    # 18 endpoints, live server, exit 1 on break
```

Its expectations are each route's *contract*, not a wish for `200`: `/api/app/*` answers
`404` when nothing is published for the channel, and `/api/cast/status` answers `400` when
no cast is active. Both are working routes; `CastRepository.status()` catches the
`DioException` and returns `null`, so polling while idle is normal. Do not "fix" those
into `200`s — that would be changing a documented behaviour to satisfy a bad probe.

**Corollary for the web UI:** removing or rewriting a Jinja page cannot break the Android
app, so it is a *product* decision, not a compatibility constraint. What must not be
deleted is the **coverage**: any test asserting on a page that is being replaced should be
migrated to its React equivalent or retired deliberately, never left failing. All 36 legacy
HTML tests have been ported to assert SPA shell status and real API contracts. See
`docs/PROJECT_STATUS.md` for details.

- **Werkzeug SPA Route Catch-All Invariant:**
  When mounting a React SPA catch-all route alongside backend API routes in Flask/Werkzeug,
  never use a naive `/<path:path>`. Werkzeug rule dispatch prioritizes rules matching the
  requested HTTP method over returning `405 MethodNotAllowed` on non-matching blueprint routes.
  A naive catch-all intercepts GET requests on POST-only API routes (e.g. `GET /api/transcode/start/...`)
  and unknown API routes, incorrectly serving 200 `index.html`.
  Always enforce routing isolation via `SpaPathConverter` using negative lookahead:
  `r'(?!(?:api|auth|media|hls|subtitles|poster|tmdb-poster|tmdb-backdrop|static)/).+'`,
  registered as `app_instance.url_map.converters['spa_path']` and `@app_instance.route("/<spa_path:path>")`.

## 8. Model routing, verification and project memory

Work on this repository is performed by **one Hermes profile** (`default`); kanban assignee = profile
name and `hermes kanban assignees` is the source of truth for dispatch. Model diversity replaces
profile diversity: whoever writes an artefact, a *different* model verifies it.

| Model | Role | Owns | Must not own |
| --- | --- | --- | --- |
| `deepseek/deepseek-v4.1-flash` (main agent) | Lead Developer / Architect | requirements, architecture, backend, database, APIs, major features, cross-cutting changes, final integration, correctness review | being the only reviewer of its own work |
| `upstage/solar-pro4:free` (auxiliary slots + subagents, $0) | Reconnaissance / mechanical verification | exploring unfamiliar code, tracing flows, reading logs, running CLI/tests, mechanical diff review, kanban spec fleshing | the correctness gate for transcode/player changes; final architecture decisions |
| `stepfun/step-3.7-flash:free` (vision, $0) | Visual inspection | UI and telemetry screenshots, visual evidence, OCR of rendered output | source-level verification |

Rules:

- **Verification is done by a model that did not write the artefact.** A free model's review is a
  breadth pass, never the gate: route an implementation card and its review card to different models
  (`hermes kanban create … --model <id> --provider nous`).
- **Verify delegated work in proportion to blast radius:** always re-check claims of absence or
  safety ("nothing references X", "unused", "no other caller") and anything about to be acted on,
  with the cheapest decisive command; spot-check the rest and label each claim verified / inferred /
  unverified.
- **Persistent project memory lives in the Obsidian vault** at
  `C:\Users\anis7\Documents\Obsidian Vault\Media Server\` (`OBSIDIAN_VAULT_PATH` is set in every
  Hermes profile). Read `Media Server — Memory Index` and `Gotchas & Pitfalls` before non-trivial
  work, and append dated entries to `Decisions Log` / `Verification Log` afterwards. Append only —
  never rewrite another agent's entry. Code and architecture facts stay in this file and `docs/`.
- **Routing pins and their rationale live in the vault note `Model Routing & Cost`** — read it before
  changing any model configuration, and verify a slot's actual model in `~/.hermes/logs/agent.log`
  or the `session_model_usage` table rather than assuming.
- Task state, assignment and verification gates live on the kanban board (`media-server`), not in
  chat.

## 9. Native Rust Subtitle Engine, Database Test Isolation & Routing Invariants

- **Native Independence Invariant (Zero Proxy Shims During Migration):**
  When migrating features or endpoints to the Rust API foundation (port 8001), always build 100% native Rust implementations directly (e.g. native gzip decompression via `flate2`, HTTP queries via `reqwest`, media probing via `ffprobe`, container extraction via `ffmpeg`). Do not create temporary reverse-proxy shims or delegators to the legacy Flask backend unless a specific migration phase explicitly mandates an interim fallback. The architectural goal is full decommission of Flask.
- **Database Test Isolation & Teardown Guardrail:**
  Any test suite or harness in Rust or Python that inserts test movie or progress rows into `media_server` (PostgreSQL) or `media.db` (SQLite) MUST clean up lingering test records during setup (e.g. `DELETE FROM movies WHERE filename LIKE 'rust_test_movie_%'`), implement an explicit teardown hook (`harness.teardown().await` or fixture cleanup) deleting test rows, and guarantee zero phantom test movies remain in development or production databases.
- **Axum Wildcard Routing & Internal Prefix Dispatcher:**
  Axum's radix router strictly forbids overlapping wildcard parameters under the same parent prefix (e.g. `/subtitles/{*path}` and `/subtitles/embedded/{*path}`). Multi-mode stream handlers must register a single wildcard endpoint (e.g. `/subtitles/{*path}`) and dispatch internally using string prefix matching (`clean.strip_prefix("embedded/")`, `clean.strip_prefix("online/")`) before falling back to local files.
- **Recursive Media Path Resolution Fallback:**
  Media files referenced by bare filenames across subdirectories must resolve safely across media roots using bounded recursive search in `PathResolver::resolve_media_path`, preserving strict directory traversal (`..`) security defenses.

