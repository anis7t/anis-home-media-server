# Agent Instructions — Anis' Media Server

## 0. Standing working rules

These three rules govern **all** work in this repository. Rules 0.1 and 0.2 added 2026-10-16; rule 0.3 added 2026-10-23.

### 0.1 Ask before drafting a plan, then plan first and ask for approval

**Always ask the user before drafting an implementation plan.** Do not draft or write an implementation plan document until the user has explicitly requested or approved doing so.

Once approved to draft a plan, before implementing anything non-trivial, **present an implementation plan and explicitly request approval.** Do not begin the work on the strength of having described it.

A plan must state, at minimum:

- **Scope** — what changes and what deliberately does not.
- **Exit criteria** — how completion is judged, stated as something checkable.
- **Risks** — what could break, and how it would be caught.
- **Open decisions** — choices that are the user's to make, not defaults to pick silently.

If the plan is revised mid-implementation, re-present it before continuing.

### 0.2 Flask and Waitress are permanently decommissioned — 100% Rust + React

`app/` (Flask, Waitress) and its Jinja templates are **100% RETIRED AND DECOMMISSIONED** (completed in Phase 7 Slice 7E).
The production backend is 100% native Rust (`:8000`), the frontend is a 100% React 19 SPA (`web/dist/`), and persistence is 100% PostgreSQL 18.4 (`MediaServerPG`).

- **Do not introduce Python web frameworks.** All new routes, services, APIs, and background workers belong natively in Rust (`rust/`).
- **All proxy bridges are retired.** There is zero reverse proxying or hybrid hosting. All endpoints (`/api/*`, `/media/*`, `/hls/*`, `/subtitles/*`, `/poster/*`, `/auth/*`, `/manage/*`, `/download`) are served directly by Axum.
- Keep the Flutter/Fire TV client working throughout; `/api/*` contract shapes must not change underneath it (guarded by `scripts/probe_android_api.py`).

### 0.3 Always use the question tool, when the harness provides one

**Always use the harness's structured question tool (OpenCode calls it the `question` tool) if it is available.** Every question put to the user goes through that tool instead of plain prose — approval gates (including the plan approval in 0.1), the open decisions a plan raises, clarifications, and any "which option?" choice. Prose is the fallback only when no such tool exists, and then say so explicitly.

- The plan itself is still presented in full first; the question tool carries the approval question, not the plan.
- Keep options concrete, distinct and short, and mark the preferred one "(Recommended)" when another option is not clearly better.
- A question answered through the tool does not remove the need to honour 0.1 — approval is still explicit, and implementation still waits for it.

## 1. Project identity and source of truth

- Repository: `anis7t/media-server`
- **Stack: 100% Rust/Axum (`:8000`) + React 19 SPA + PostgreSQL 18.4.** Flask, Waitress, SQLite, and Jinja templates are **COMPLETELY RETIRED AND DECOMMISSIONED**.
- Backend: Modular Rust crate (`rust/`) with Axum 0.8, Tokio, SQLx, and tracing.
- Frontend: Single Page Application in React 19 + TypeScript + Vite (`web/`), served directly by Axum from `web/dist/`.
- Database: PostgreSQL 18.4 running as Windows Service `MediaServerPG` on port 5432.
- **No Python runtime utilities remain.** Library ingestion is native Rust
  (`rust/src/scanner/` + `rust/src/services/scan_service.rs`); the old `scanner.py` was deleted in
  `4793fdb` (Phase 10.5).
- `docs/PROJECT_STATUS.md` is the primary current handoff: it records completed work, known bugs, platform requirements, testing requirements, and the immediate work queue. Read it before substantial changes.
- **Session handoffs live in `Handoffs/`**, named `YYYY-MM-DD_HH-MM_<agent>.md` in IST.
- **Where the migration stands** is `docs/MIGRATION_STATUS.md` (all phases P0–P9 and Slice 7E 100% complete); the authoritative roadmap is in `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`.
- `docs/DEVELOPMENT_STATUS.md` and `docs/WINDOWS_SETUP.md` contain the detailed current Windows/AMF and persistent service state. `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md` contains the remote-access history and named-tunnel configuration.
- `docs/MULTI_GPU_CHUNKED_TRANSCODING_PROPOSAL.md` documents the dynamic multi-GPU chunked transcoding architecture implemented in Rust (`rust/src/transcode/` and `rust/src/services/gpu.rs`).
- `docs/OPENING_SEQUENCE.md` documents the brand opening-sequence overlay. **Part I is the canonical
  specification** — the timing table, the layer stack, the compositing / responsive / audio /
  dismissal / reduced-motion contracts, and the divergence ledger. Every Phase 11 slice is written
  from it. Part II is the historical record (the loss, the artifacts, the verification).
  **Status: the web overlay IS implemented, and is verified frame-for-frame.** It was a Jinja2
  template (`templates/intro-overlay.html`), deleted with the other legacy templates in Slice 7E.2
  (`5a2af4f`, 2026-10-18), and no React component was ever written to replace it — an earlier
  version of this line claimed it was wired into the React SPA, and that claim is what let the
  regression go unnoticed for two days. **The React port now exists**: the canonical renderer
  (`web/src/lib/intro/`), the overlay (`web/src/components/brand/BrandIntroOverlay.tsx`), the
  lifecycle and modes (`web/src/hooks/useIntroSequence.ts`) and the live Web Audio score
  (`web/src/lib/intro/audio.ts`). It is **pixel-identical to the archived original** at 20 sampled
  instants in both orientations — `web/e2e/intro-frame.spec.ts` — and the score builds the
  **same audio graph** as the original — `web/e2e/intro-audio.spec.ts`. The **Flutter client still
  has its own, divergent, copy** (see the invariant below). The web port is **Phase 11**; Slices
  11.1 (the canonical spec), 11.1a (the Flutter Replay removal), 11.2 (the web canvas renderer),
  11.3 (the web lifecycle, gating and modes) and 11.3a (the web Web Audio score) are complete, and
  11.4 onward await slice-by-slice approval:
  [`docs/PHASE_11_OPENING_SEQUENCE_PLAN.md`](docs/PHASE_11_OPENING_SEQUENCE_PLAN.md).

### Brand Opening Sequence (Intro Overlay) Invariants

> **The canonical design is [`docs/OPENING_SEQUENCE.md`](docs/OPENING_SEQUENCE.md) Part I.** Where
> this block and that spec disagree, the spec wins. Every Phase 11 slice is written from it.
>
> **The web invariants below now describe code that exists and is tested.** The React port is
> `web/src/lib/intro/` (the canonical renderer), `web/src/components/brand/BrandIntroOverlay.tsx`
> (the overlay) and `web/src/hooks/useIntroSequence.ts` (the lifecycle). It is verified
> frame-for-frame against the archived original by `web/e2e/intro-frame.spec.ts`, and its score is
> verified against the original's own Web Audio by `web/e2e/intro-audio.spec.ts`. The Flutter
> invariant, by contrast, still describes code that is **divergent** from the canonical design.

- **Prompt-Free Autoplay by Default:** The brand intro overlay auto-starts immediately upon app load (`mode = 'auto'`) without requiring user interaction or displaying a click-to-start gate prompt (`#gate` has `display: none !important;`). The gate card is reserved strictly for manual testing via `?intro=gate`. `auto` is the default for the injected overlay; `gate` was the *standalone* page's default and is not the product behaviour.
- **Non-Blocking Web Audio Resiliency:** Browser autoplay restrictions on the Web Audio API never block or delay visual animation playback. The 3.0-second canvas render loop and veil parting run unconditionally; Web Audio attempts immediate playback and attaches transparent, one-time document listeners (`pointerdown`, `keydown`, `touchstart`) to resume `AudioContext` seamlessly upon first user gesture. **The audio must never gate the animation** — that single rule is the difference between a prompt-free intro and a broken one. In the React port this is *structural*: `web/src/lib/intro/`'s renderer has no reference to the audio module at all, and the score's `start()` returns `false` rather than throwing when there is no Web Audio.
- **The Score Is Anchored, Not Orphaned (web):** The score's zero is placed at `ctx.currentTime + RAMP - elapsed`, where `elapsed` is how far the animation has already played — so the score lands on the animation's own beats. A voice whose beat has already passed is **skipped**, not fired late. A context that resumes **after** the animation has ended gets **no score at all**: a three-second score playing out of nowhere is worse than no score. The original's behaviour (schedule the whole score at `ctx.currentTime + RAMP` and let a frozen clock hold it) is **not** ported.
- **The Unlocking Gesture Is Consumed By The Audio (web):** The first gesture while the `AudioContext` is still suspended resumes it and starts the score in step with the animation, and **the animation continues** — a second gesture dismisses. The cost, stated plainly: **the first click during the intro no longer skips it.** `m` **mutes and does not dismiss**, because the gate's own hint says *"`m` mutes"*.
- **The Score's Noise Is Seeded (web):** The port draws its reverb impulse response and its noise buffers from a fixed seed, so two renders of the same score are the same signal. The original used `Math.random()` and was never bit-reproducible. The perceptual difference is nil — it is noise either way.
- **The Web's Reference Is The Original's Web Audio, Not The WAV:** `intro-theme.wav` is the *Python* renderer's output, and the Python sweeps a resonant **low-pass** over its noise beds where the original's Web Audio uses a **band-pass** — the two are not the same synthesis. The WAV is the **Flutter** client's reference; the archived overlay's `window.INTRO.audio` is the **web** port's. A port that "matches the WAV sample for sample" is chasing the wrong target.
- **Container-Controlled Session Gating:** `intro-overlay` does not set `sessionStorage.setItem('introSeen')` prior to the enclosing component's evaluation.
- **No Visible Skip and No Replay, Anywhere:** The canonical design exposes **no Skip control and no Replay control on any target**, including the Flutter Settings screen. The archived source's HUD is hidden by default (`SHOW_HUD=false`) and is a demo affordance, not a product surface; dismissal is implicit (click / tap / space / any key). The Flutter "Replay Brand Intro" action was removed in Phase 11 Slice 11.1a.
- **Reduced Motion Is A Cross-Target Contract:** `prefers-reduced-motion: reduce` suppresses exactly four things — the impact burst particles, the camera shake, and the icon's rotation and scale — on **all three** targets, not the web alone.
- **The Curtain Is Opaque And The Outro Is A Reveal:** The stage is **transparent** and carries an **opaque obsidian curtain** (`#05060a` web / `Color(0xFF05060A)` Flutter) over the live app. The app is revealed by the two halves **sliding apart**, never by removing an opaque panel (which would make the outro a flash). At `t >= curtain + 0.62` (2.57 s) the overlay releases `pointer-events`, so the app underneath is interactive for the final **0.43 s**.
- **Layer Order Is Load-Bearing:** `veilL/veilR (z2) → seam (z3) → FX canvas (z4) → vignette (z5) → grain (z6) → lockup (z7) → HUD (z8, hidden)`. **The FX canvas is ABOVE the curtain.** Putting it below makes the entire `0.12 – 1.95 s` build-up invisible — which is exactly the bug the Flutter client had until Slice 11.4.
- **The Lockup Rule Is A Breakpoint, Not A Constant:** side by side in landscape, **stacked in portrait** (`H > W`). The Flutter client now follows this rule (Slice 11.4). Do not make its lockup side-by-side unconditionally — the phone is portrait and is already correct; the TV is landscape and is not.
- **The Sequence Is Resolution-Independent, And That Is Proven, Not Assumed:** the web's oracle puts the **archived original** and the port side by side at **five** viewports — landscape, portrait, ultrawide (2560 × 1080), tablet (1024 × 1366) and a modern phone (1080 × 2400) — and compares them **pixel for pixel**. The Flutter client's sweep asserts the same five: the lockup's arrangement follows the breakpoint, the canonical's clamps hold, nothing overflows, and the parameters match the canonical's frame fixture at that aspect's design unit. The archived original is a standalone document that can be laid out at **any** viewport, so this is an exact comparison, not a tolerance against a reference that exists at two aspects only.
- **The Reference Frames Are The Shipped Implementation's:** `docs/opening-sequence/frames/` and `frames-portrait/` are re-captured from the **shipped** implementation by `scripts/capture-shipped-frames.mjs`, which first proves the capture **reproducible** (two runs byte-identical where the curtain is closed) and **faithful** (the new frames compared pixel by pixel with the archived ones). They are replaced **only if** that comparison passes. The archived frames were captured in a different browser, so the SVG grain's turbulence (1–2 units over the whole frame) and the Gaussian blur on the wordmarks do not rasterise the same way — which is why the claim is a *perceptual* one, on the same metric the Flutter client's oracle uses.
- **Mobile Client Opening Sequence (Flutter) — ALIGNED, as of Phase 11 Slice 11.4 (2026-10-20), and it has a score since 11.5:** Autoplays on cold boot launch in `AppShell` as a `CustomPaint` re-implementation (it is **not** video playback - the dead `assets/videos/intro-demo-portrait.mp4` was **removed** in Slice 11.5, taking 2.4 MB out of every APK), and `IntroController` sets `isPlaying: true` unconditionally - so it plays on **every launch**, which is now **deliberate**: the dead `hasSeenIntro` flag is gone and the behaviour is stated. Dismissal is implicit: a tap anywhere, or any key. The visible **Skip pill** is **gone**; the Settings **"Replay Brand Intro"** action was removed in Slice 11.1a (D4). The FX canvas is now **above** the curtain, with all seven effects and the sheen implemented, and there is a grain layer. The lockup is **responsive** - side by side in landscape, stacked in portrait, decided by the **stage's aspect** and never by the device type. The curtain **translates** (it does not shrink), overlaps by 1 px, feathers its inner edges only once parting, and carries **one** continuous gradient across both halves. The outro is a **removal** at 3.00 s, not a fade. `prefers-reduced-motion` is honoured and suppresses exactly four things. The mark is the canonical artwork, path for path. **The score** (Slice 11.5) is the canonical's `intro-theme.wav`, shipped **byte for byte** (the suite asserts its SHA-256) and played through `audioplayers`; it is **anchored to the sequence** when the player becomes ready, **dropped** if the sequence is over, and **the animation never waits for it**. Implementation: `flutter_client/lib/features/intro/` - `domain/` (the contract and the pure core), `infrastructure/` (the player), `presentation/` (the painters, the widgets and the controllers), `presentation/providers/`. The divergence ledger is `docs/OPENING_SEQUENCE.md` Part I §12; the three recorded divergences are **L3** (the grain: Flutter cannot render the canonical's SVG `feTurbulence`, so it uses a seeded white-noise texture of the same tile size and colour matrix), **L17** (the handover: Flutter releases touches at 2.57 s but keeps the keyboard for the whole three seconds, so a D-pad press cannot navigate the app behind the sequence) and **L18** (the score has **no unlocking gesture** - Android has no autoplay policy, so the intro makes a sound on every cold launch - and **no `m` mute**, because any key dismisses). Fullscreen video player routes (`/player`, `/player-poc`) remain strictly isolated. Tests: `flutter_client/test/features/intro/`.

## 2. Current architecture

```text
Browser / Client (Desktop, Tablet, Mobile) / Android App / Fire TV Stick 4K
  -> Caddy :443/:80 (MediaServerCaddy NSSM service, Let's Encrypt)
  -> http://127.0.0.1:8000
  -> Rust Axum Server (MediaServerRust NSSM Windows Service)
     ├─ React 19 SPA (web/dist/ static file serving + SPA fallback)
     ├─ API Router (rust/src/routes/ - api, auth, media, hls, subtitles, download, manage, etc.)
     ├─ Services (rust/src/services/ - catalog, progress, cast, device, system, probe, etc.)
     ├─ Transcode Engine (rust/src/transcode/ - autonomous dual-GPU chunked fMP4)
     │  ├─ AMD Radeon RX 560X (discrete, dx11:1)
     │  └─ AMD Radeon Vega 8 (integrated, dx11:0)
     ├─ Live seek frame preview cache (E:\MediaServer\cache\previews\)
     ├─ PostgreSQL 18.4 (MediaServerPG Windows Service, port 5432)
     └─ Local Media Root (D:\Flicks, D:\Flicks\.archive, D:\Flicks\.uploads)
```

Important modules:

- `rust/src/main.rs` & `rust/src/lib.rs` — Axum application setup and router composition.
- `rust/src/config.rs` — environment-driven settings (`.env`).
- `rust/src/db.rs` — PostgreSQL connection pool (SQLx).
- `rust/src/routes/` — API handlers (`api.rs`, `auth.rs`, `media.rs`, `hls.rs`, `subtitles.rs`, `download.rs`, `manage.rs`, etc.).
- `rust/src/services/` — backend services (`catalog.rs`, `device.rs`, `system.rs`, `cast.rs`, `progress.rs`, `gpu.rs`, `preview.rs`, `scan_service.rs`, `tmdb.rs`).
- `rust/src/scanner/` — native library scanning engine (`engine.rs`, `parser.rs`, `models.rs`, `tmdb_client.rs`), driven by `scan_service.rs`.
- `rust/src/transcode/` — chunked multi-GPU fMP4 transcoding pipeline (`engine.rs`, `planner.rs`, `queue.rs`, `sweeper.rs`).
- `web/src/` — React 19 SPA frontend (components, pages, lib, hooks).

## 3. Completed capabilities

The current project includes:

- **Direct Play:** Zero-copy RFC 7233 byte-range playback for MP4/M4V/WebM.
- **Dynamic Multi-GPU Transcoding:** Concurrent chunk-based encoding across discrete AMD Radeon RX 560X (`dx11:1`) and integrated AMD Radeon Vega 8 (`dx11:0`).
- **Live Multi-GPU Telemetry:** Real-time hardware engine utilization tracking via Windows Performance Counters and PyNVML displayed on the System Telemetry HUD.
- **Live Seek Hover Previews:** Frame thumbnails extracted on-demand via `rust/src/services/preview_service.rs` and cached in `cache/previews/`.
- **1-Second Transcode Cadence:** High-frequency status polling for smooth progress bars, fps/speed reporting, and smoothed ETA calculations.
- **Windows Persistent Services:** `MediaServerRust` (Axum via NSSM on port 8000), `MediaServerCaddy` (Caddy reverse proxy and TLS on 80/443 via NSSM), and `MediaServerPG` (PostgreSQL 18.4 native Windows service on 5432) start automatically, survive reboots, and have crash recovery; Rust and Caddy logs rotate at 10 MB.
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
- **Dual-Drive Storage Tiering & Cross-Volume Cache Resilience:** Tiered architecture keeping all runtime state on the primary fast SSD `E:` — application (`E:\MediaServer`), PostgreSQL data directory (`E:\pgdata`), in-progress transcode scratch, seek-preview thumbnails, and completed HLS cache (`E:\MediaServer\cache\hls`) — while offloading cold raw media, resumable upload staging, and source archives to the high-capacity secondary drive `D:` (`D:\Flicks`, `D:\Flicks\.archive`, `D:\Flicks\.uploads`, `D:\Flicks\.deleted`). `C:` holds nothing for this project. Telemetry aggregates `D:` and `E:` into a single Storage Pool with a per-drive breakdown (`system_service.rs` `target_mounts`). Includes dynamic multi-root discovery (`get_media_roots()`), cross-volume relative-path cache key preservation in `hls_cache_dir()` and `preview_dir()`, and cross-volume sidecar subtitle resolution and authorization.
- **Cross-Root Mirror Subtitle Discovery & HLS Seeking Stabilization:** Subtitle engine automatically discovers sidecar `.srt`/`.vtt` files across mirror subdirectories in any configured media root (stripping `.archive` paths) for archived media (e.g. *The Odyssey*), and player seeking event handlers guard `jumpStartGap()` and `checkPreparing()` against in-flight user scrubbing and active seeks, eliminating playback stalls and `0:00` resets.
- **Unified Navigation Header & Brand Identity:** Redesigned frosted obsidian glass header with 3D glossy play SVG brand icon, two-tone typography (**Anis'** + **Home Media Server**), subtitle (**PLAY • ORGANIZE • ENJOY**), modular SVG pill buttons, and responsive horizontal swipeable action rails across all pages (`/`, `/movie/<filename>`, `/player/<filename>`, `/manage`, `/devices`, `/manual`).
- **Universal Customizable `<select>` Popovers:** Modernized dropdown pickers using `appearance: base-select` and `select::picker(select)` across `/manage`, playback speed, and subtitle settings with obsidian glass styling and brand red active highlights.
- **Library Navigation Density & Hierarchy:** Removed redundant A-Z sort dropdown across desktop and mobile, and repositioned System Telemetry HUD to the bottom of the home page (strictly after "All Movies"), prioritizing library browsing.
- **Mobile Player Controls Expansion & Dedicated Seekbar Spacing:** Restored primary controls (`↺` Restart, `🔊` Mute, `1×` Speed, `CC ⚙` Subtitles/Settings, Aspect Ratio, Rotate Screen, PiP, Nerd Stats) on mobile inside a swipeable non-overflowing rail, cleanly hid redundant desktop-only buttons (`#volume`, `#shortcutsBtn`, and `-10`/`+10` seek buttons), and eliminated vertical gap between `.seek-time-row` and seekbar (`margin-bottom: -9px !important`).
- **Interactive User Manual & Footer Navigation:** Added in-app User Manual (`/manual`) with full shortcuts cheatsheet, touch gestures, multi-GPU streaming guide, and footer "How to use" link. Authored offline user guide in `docs/MANUAL.md`.
- **Flutter Client Production Player:** Native Android & mobile Flutter client with translucent gradient controls overlay, symmetrical equidistant seekbar spacing (~6dp), dual-time anchor HUD (elapsed time left, total/remaining time right with tap-to-toggle), canonical web button sequence (`↺` Restart, `⏸`/`▶` Play/Pause, `🔊` Mute, `1×` Speed, Audio, Subtitles), vertical-swipe volume/brightness controls (left half = brightness, right half = system media volume, native channels), watch-progress persistence (`PlaybackProgressReporter`), and rapid direct-intent test automation (`--es route "/player"`).
- **Universal Android APK & 10-Foot TV Experience (Fire TV Stick 4K & Android TV):** Single universal APK (`in.anisparvez.media_server_client`) operating seamlessly across mobile phones (touch UI + bottom bar) and Android TV / Fire TV Stick 4K (`AFTMM`) (10-foot D-pad remote UI + collapsible obsidian side rail + borderless fullscreen cinema player). Runtime capability detection (`deviceCapabilitiesProvider`), 2-column details with autofocus action (`autofocus: true`), 2-zone remote transport model (Zone 1 Timeline, Zone 2 Controls), edge traversal bridge (`TvDirectionalFocusAction`), and debounced exit dialog (`TvExitDialog`).
- **Fire TV Stick 4K Hardware Playback Hardening & Driver Lock Prevention:** Resolved low-level MediaTek Display Processor (MDP) kernel fence deadlock and PowerVR GE9215 GPU desynchronization on Amazon Fire TV Stick 4K (`AFTMM`) using `mediacodec-copy`, preventing direct `SurfaceTexture` / `ANativeWindow` fence timeouts on non-16-byte-aligned dimensions (e.g. 1916px) with automatic dynamic software fallback (`fallbackToSoftwareDecoder`, `hwdec: no`) and buffer flush seek.
- **LAN Cast & DLNA Second-Screen Playback:** Cross-platform casting to DLNA TVs (Samsung Tizen, LG webOS) and Google Cast devices (Chromecast with Google TV, Nest Hub). Direct byte-range delivery for DLNA and web-friendly MP4/WebM, HLS for Matroska/HEVC on Chromecast, real-time receiver master volume tracking and 3-state mute toggle, WebVTT subtitle track delivery with live in-cast selector popover, and clean receiver app quit (`cast.quit_app()`) restoring the TV to its home screen upon disconnect.
- **Phase 8 Fragmented MP4 (fMP4) Adaptive Streaming Architecture:** Modernized HLS streaming pipeline from legacy MPEG-2 Transport Stream (`.ts`) to ISO BMFF Fragmented MP4 (`.m4s` / `fMP4`) with `#EXT-X-MAP` initialization segments, unlocking native hardware-accelerated HEVC and H.264 playback across Chromium (Chrome, Edge) and Safari browsers with zero JavaScript demuxing overhead. Includes dynamic multi-bitrate quality ladder (4K, 2K, 1080p, 720p, 480p, 360p) with strict no-upscaling clamping, on-demand single-stream transcoding (Option A), Android/Fire TV MKV Direct Play (0% server load), and user-facing terminology modernization retiring developer-facing "HLS" labels.

## 4. Known unresolved issues & active roadmap

### Completed high-priority items

- **100% Rust + React + PostgreSQL Migration:** (Completed 2026-10-18)
  All 10 migration phases (P0–P9, including Slice 7E Legacy Flask Decommissioning) are 100% delivered, hardened, and verified.
  The production server runs exclusively on Rust Axum (`MediaServerRust`, port 8000), PostgreSQL 18.4 (`MediaServerPG`, port 5432), and React 19 SPA (`web/dist/`).
- **Production concurrency tuning & remote streaming benchmarks:** (Completed 2026-10-14)
  Evaluated local origin and Cloudflare named tunnel (`media.anisparvez.in`) across Direct Play, HLS segment streaming, and mixed API workloads (concurrency 1–16). Local aggregate throughput reached **510.86 Mbps** on Rust Axum with 100% success; remote throughput capped at **18.43 Mbps** due to physical ISP uplink (~20 Mbps). Documented in [`docs/STREAMING_BENCHMARK_REPORT.md`](docs/STREAMING_BENCHMARK_REPORT.md).

### Highest priority — immediate work queue

1. **Production Maintenance & Feature Additions:**
   The codebase is 100% modernized on native Rust, React, and PostgreSQL. All new development proceeds natively in Rust (`rust/`) and React (`web/`).
2. ~~Bind `GET /api/auth/qr/{id}/finalize` to the waiting device.~~ **DONE 2026-10-23.**
   The route now requires the per-session CSPRNG secret issued at create time, delivered in a
   path-scoped `HttpOnly` cookie and stored only as `secret_hash`; missing or wrong → **403 with no
   session cookie**. Verified live: 403 without the cookie, 400 (not yet confirmed) with it.
   See the QR invariants above.
3. ~~Rate-limit the QR endpoints and cap concurrent SSE connections.~~ **DONE 2026-10-23.**
   Every QR route now has a per-client sliding window (create 10/min, lookup and confirm 20/min,
   finalize 30/min, wait 10/min, status 120/min) answering **429 with `Retry-After`**, and SSE
   streams are capped at **64 global** (`MEDIA_SERVER_QR_MAX_SSE`) and **4 per client**, with the
   permit owned by the response stream so a disconnect returns the capacity. See the QR invariants
   above.
4. ~~Drop the plaintext `code` column from `device_pair_sessions`.~~ **DONE 2026-10-23.**
   Lookup and confirmation compare against `code_hash` only; the column was dropped by
   `ALTER TABLE ... DROP COLUMN IF EXISTS code`, and its index was replaced by
   `idx_device_pair_code_hash`. Verified live: the column is gone from `information_schema`, a
   create still succeeds, and the schema shows `code_hash` + `secret_hash`. **Rolling back to a
   pre-drop binary requires re-adding the column first.** See the QR invariants above.
5. **Port the web opening sequence to React.** The brand intro overlay was a Jinja2 template and
   was deleted in Slice 7E.2 without a replacement, so the web app had no intro from 2026-10-18
   until 2026-10-20. **Phase 11 is COMPLETE**: Slices 11.1 (the canonical specification), 11.1a
   (removing the Flutter Replay action), **11.2 (the web canvas renderer)**, **11.3 (the web
   lifecycle, gating and modes)**, **11.3a (the web Web Audio score)**, **11.4 (the Flutter client,
   aligned)**, **11.5 (the Flutter score)** and **11.6 (the responsive sweep and the asset
   regeneration)** are all done. The roadmap is
   [`docs/PHASE_11_OPENING_SEQUENCE_PLAN.md`](docs/PHASE_11_OPENING_SEQUENCE_PLAN.md).
   The renderer is **pixel-identical to the archived original at five viewports**, and the **shipped
   app** is compared against the same harness (`web/e2e/intro-frame.spec.ts`). The score is live Web
   Audio on the web (`web/src/lib/intro/audio.ts`) and the canonical's WAV on the phone and the TV.
   The Flutter client is a **port of the canonical renderer**, and its score is the canonical's file
   byte for byte. **The on-device session happened on 2026-10-21 and it changed the picture:**
   * the **phone is verified** — it shows the canonical design exactly, in portrait, and it plays
     the score;
   * the **launch window was white** on both devices, and it is **fixed and verified by pixel**:
     the `drawable-v21` variant of the launch background is the one Android picks on API 21+, and
     it said `?android:colorBackground`, which is white under the Light theme. It now carries the
     curtain's `#05060a`, and a `screencap` taken during a cold launch reads `R=5 G=6 B=10`;
   * the **Fire TV cannot render the sequence**: its 2015 PowerVR Rogue GE8300 has no Vulkan, so
     Impeller is unavailable and Skia compiles each new draw program at runtime — the first frame's
     raster takes **1.09 seconds**, and the three-second sequence gets **five frames**. Two
     remedies were tried and **rejected by the measurement** (a `ShaderWarmUp`, and moving the
     clock's origin); both are recorded in the plan so they are not attempted again.
   **Slices 11.7 and 11.8 are DONE (2026-10-21).** The television plays a **pre-rendered video**
   of the sequence, rendered from the shipped web application (the canonical) by
   `scripts/capture-intro-video.mjs` and verified against the canonical's reference frames by
   `scripts/verify-intro-video.mjs` — the worst mean error over the 58 closed-curtain frames is
   **5.33/255**, and it is all in the grain, which is the one thing a codec cannot carry. The
   score stays a separate byte-for-byte canonical WAV, anchored to the **video's** position, and
   the phone keeps the live sequence. The four divergences this creates are in the ledger as
   **L19–L22**. Slice 11.8 is the one-line fix for the yellow underlines the phone showed, which
   came from the wordmarks inheriting the ambient text style's decoration — a thing the oracle
   cannot see, because a test's ambient style never carries one.
   **What is left is the device check**: the video has to be seen on the television, and the
   sequence's audio with it. See
   [`docs/PHASE_11_OPENING_SEQUENCE_PLAN.md`](docs/PHASE_11_OPENING_SEQUENCE_PLAN.md).
   **One open finding** from 11.3a: the web's score renders about **6 dB quieter** than the archived
   original's Web Audio, and the cause is not yet isolated (spec section 7.9 lists everything that
   was measured and ruled out).
6. ~~Three Flutter test files cannot run on this host — `libmpv-2.dll` is missing.~~ **DONE 2026-10-23.**
   `runtime_player_3a_test.dart`, `runtime_player_3b_test.dart` and `app_shell_test.dart` failed in
   `setUpAll` with `Cannot find libmpv-2.dll in your system %PATH%`, because they call
   `MediaKit.ensureInitialized()` and media_kit's **Windows** native libraries were not installed
   here. The client targets **Android**, where media_kit does not use libmpv, so the **shipped app
   was never affected** — only these host-side Dart-VM tests could not run.
   **Fix: `scripts/fetch_libmpv.ps1`** provisions exactly the archive our own dependency already
   pins — `media_kit_libs_windows_video 1.0.11`'s `windows/CMakeLists.txt` downloads
   `mpv-dev-x86_64-20230924-git-652a1dd.7z` and checks **MD5 `a832ef24b3a6ff97cd2560b5b9d04cd8`** —
   verifies it before extraction, fails closed on mismatch, and places `libmpv-2.dll` at
   `flutter_client/build/windows/x64/runner/Release/`, the exact path all three files already
   prefer. That directory is **gitignored**; nothing fetched is ever committed. **Re-run the script
   after `flutter clean`**, which deletes it. **Dropping `ensureInitialized()` was rejected as a
   fix**: `runtime_player_3a_test.dart`'s non-live test constructs a real `MediaKitPlayerAdapter`
   (whose constructor builds a real `Player`), and `app_shell_test.dart` pumps the production
   `/player` route — both genuinely need natives.
   **Measured after provisioning:** the three files `+7 ~4`, and the **full suite `+327 ~12`, 0
   failures**, `flutter analyze` clean. The suite is **green here** — the old "no new failures,
   name the pre-existing three" bar is retired. The live-gated tests remain skipped by default
   (`MEDIA_SERVER_LIVE_TESTS=1` opts in; they play a production file and write device telemetry).
   Tracked as Issue 11 in [`docs/Current issues.md`](docs/Current%20issues.md).
7. **The Flask/Waitress era left three loose ends** (the backend is 100 % native Rust — Axum on
   `:8000`; no `flask` and no `waitress` is installed anywhere). The footer badge and the
   agent-facing Serena memories are **fixed**; three remain: the `media-db` MCP server still
   serves a snapshot of the **retired SQLite** database rather than PostgreSQL; the stopped
   `MediaServer` NSSM service is still registered (inert — its entry point no longer exists) and
   removing it is the owner's call; and `web/vite.config.ts` still points its "Rust" proxy at
   `:8001` and its "Flask" proxy at `:8000`, which is actually Rust — a dev-only change that
   needs the un-migrated endpoint list confirmed first. Tracked as Issue 12 in
   [`docs/Current issues.md`](docs/Current%20issues.md).

### Secondary / parked

5. **Automatic OpenSubtitles behavior:** local subtitles work; incorrect automatic OpenSubtitles behavior is parked.
6. **Authentication/access control — Phases 1–3 done 2026-10-23.** The stable hostname is not
   authentication. `media.anisparvez.in` is served by Caddy on a static IP, so anyone on earth
   with a Google account could sign in and (previously) become a viewer, and the allowlist
   defaulted to "allow everyone." Phase 1 closes the account-creation side:
   - `MEDIA_SERVER_ADMIN_EMAILS` (comma list) promotes those addresses to `admin` on Google
     sign-in; everyone else is `viewer`. `anis7t@gmail.com` is configured.
   - The role is re-checked against the `users` table on every request (session cookie path
     now reads `COALESCE(u.role, s.role)`), so a removal from the list takes effect immediately
     rather than at the next sign-in.
   - Upload was already admin-only (`require_admin`); it is now reachable by a signed-in admin
     account as well as the Admin PIN. Verified: admin session → past the gate, viewer session
     and anonymous → 403.
   - Admin PIN channel is untouched and remains the bootstrap/recovery path.
   - The `MEDIA_SERVER_AUTH_ALLOWLIST` was cleared so anyone can still sign in (guest browsing
     and per-user watch history stay available); only account *creation* is scoped by the admin
     list, and admin oversight is the remaining work.
   - **Phase 2 (done 2026-10-23):** `devices.user_id` and per-user scoping of the device list and
     its embedded watch history; rename/delete authorisation follows ownership. The invariants are
     in *Device ownership & watch-history scoping* below.
   - **Phase 3 (done 2026-10-23):** admin oversight — admin-only owner attribution on
     `/api/devices`, `GET /api/admin/users`, `POST /api/admin/devices/assign`,
     `POST /api/admin/devices/history/delete`, and the admin view on `/devices`. The invariants are
     in *Admin oversight of accounts, devices & watch history* below.
   The media library itself stays public (gating it would break DLNA/cast/device tokens).
7. **Backups are on the same volume as the data.** `E:\pgdata` and `E:\MediaServer\backups` are
   both on `E:`. A volume failure takes the database *and* the backups together. An off-host copy
   is the actual fix. The daily scheduled backup itself is in place — see
   [`docs/BACKUP_AND_RESTORE.md`](docs/BACKUP_AND_RESTORE.md).
8. **Rotate and scope the Cloudflare API token** in `E:\MediaServer\Caddyfile`. It is a live
   credential with DNS-management rights over the hostname, stored in plaintext on disk. The file
   is correctly gitignored, but the token should still be scoped and rotated.

### Admin authorisation invariants (`rust/src/middleware/auth.rs` & `rust/src/routes/admin.rs`)

Routes requiring admin credentials can **delete the library, purge caches, move originals into the
archive and rewrite the retention policy.** They are reachable from the public internet through
the Cloudflare tunnel. Treat them as the most destructive surface in the application.

- **The Admin PIN fails closed, and has no default.** `settings.admin_pin` defaults to empty string.
  A hard-coded default is not a safe fallback for a secret. Unset means the PIN channel is **closed**,
  leaving only an authenticated admin session, which sets the first PIN deliberately.
  `/api/admin/status` reports `has_pin` against the same empty-string default so the answers never disagree.
- **Never accept the PIN from a query string.** Query parameters leak into access logs, Cloudflare edge
  logs, browser history, and `Referer` headers. Header (`X-Admin-Pin`) and JSON body only.
- **A closed probe is not a closed door.** Any test asserting the PIN is refused must also assert a
  destructive route returns 403.
- **Do not weaken auth to make a test pass.**

### QR Device Sign-In invariants (`rust/src/routes/qr_auth.rs` & `rust/src/services/auth_service.rs`)

The QR sign-in flow is reachable from the public internet, so its secrets are load-bearing.

- **Every security token comes from the OS CSPRNG.** `getrandom` (BCryptGenRandom on Windows),
  never a clock-derived seed. This covers the pair code, the `qr_id`, the `sess_` session tokens,
  the `ms_` device tokens, the OAuth `state`/`nonce` and the PKCE `verifier`.
  - The failure mode that motivated this: `generate_pair_code()` walked one 64-bit LCG and took
    `seed % 32` per step. The LCG's multiplier and increment are both odd, so the low 5 bits of
    every step depend only on the low 5 bits of the first one — the whole code collapsed to **32
    possible values** instead of 32^5. Measured live: 40 sessions produced 15 distinct codes.
    `POST /api/auth/qr/lookup` resolves a code to a live session, so 5 bits is a guessable code.
  - `generate_random_token()` hashed `nanos ^ counter ^ pid ^ (nanos_low64 ^ const)`. A token
    minted at a known moment is a token an attacker can search for. `qr_id` was one of them, and
    `qr_id` is the *only* key to the unauthenticated `/api/auth/qr/{id}/finalize` endpoint.
- **Draw each character independently.** A shared state word whose low bits drive several output
  characters is the whole bug. `test_pair_code_has_real_entropy` requires >= 5,000 distinct codes
  from 10,000 draws; the collapsed generator produced 32.
- **Fail closed, never mint a weak secret.** If the random source is unavailable, the request errors
  rather than falling back to a guessable value. Same posture as an unset Admin PIN.
- **Never log a pair code or a full `qr_id`.** `finalize` is unauthenticated, so either one in a
  log is an account-takeover handout. The log carries a 12-hex-character reference only.
- **`byte % 32` is unbiased here and only here.** The charset is 32 characters and 256 is a
  multiple of 32, so no rejection sampling is needed. A different charset length needs it.
- **Do not trust `Host` or `X-Forwarded-Proto` for the QR URL.** `get_base_url` read them
  directly, so the emitted `qr_url` was host-header-injectable. A configured
  `MEDIA_SERVER_PUBLIC_BASE_URL` now takes precedence — **set it in the NSSM service environment
  and in `.env`**. The same applies to the Google OAuth redirect URI (`get_host_url`).
- **`finalize` is bound to the waiting device, not to the `qr_id`.** The `qr_id` travels in the QR
  URL, the SSE URL, browser history and access logs, so possessing it must never be enough to claim
  a confirmed session. `POST /api/auth/qr` issues a CSPRNG secret in a **path-scoped**
  (`Path=/api/auth/qr/<id>`), `HttpOnly`, `SameSite=Lax`, 130-second cookie, and only its SHA-256 is
  stored (`device_pair_sessions.secret_hash`). `finalize` compares in constant time and answers
  **403 with no cookie** when the secret is missing or wrong; the refusal is what the test asserts,
  not merely the happy path. The secret is never in the response body (a page must not be able to
  read it, and it must not appear in screenshots), and a successful finalize clears the cookie with
  the same `Path` that set it. Distance from the failure mode: a `qr_id` copied out of a log line
  used to buy a session inside the two-minute window; now it buys a 403.
- **Every QR route is budgeted, and SSE concurrency is capped.** The QR routes are the cheapest
  unauthenticated work on the server: `create` writes a row and `wait` holds a connection plus a
  PostgreSQL query every three seconds. Each route therefore has a per-client sliding window
  (create 10/min, lookup 20/min, confirm 20/min, finalize 30/min, wait 10/min, status 120/min),
  answering **429 with `Retry-After`**. SSE streams are capped at **64 globally**
  (`MEDIA_SERVER_QR_MAX_SSE`) and **4 per client**; the permit is owned by the **response stream**,
  so a disconnect, a timeout, or a proxy that never reads the body returns the capacity - a permit
  leaked per abandoned stream would shrink the pool permanently. The client identity is the **last**
  `X-Forwarded-For` entry (correct whether Caddy appends or replaces), else a shared `direct` bucket
  for LAN traffic; the identity table is capped at 8192 and refuses **new** identities rather than
  evicting live ones, because eviction would hand an attacker a fresh budget per spoofed address.
  This is an availability brake, not an authorization control: the counters are in-process and
  reset on restart, which is acceptable because nothing about identity depends on them.
- **The pair code is stored only as a hash, and the plaintext column is gone.** `code_hash` is the
  only form at rest; `find_pair_session_by_code` and `confirm_pair_session` both hash the
  case-normalized submission, so a code typed in lowercase still works (the generated charset is
  uppercase). The column was dropped by `ALTER TABLE ... DROP COLUMN IF EXISTS code` in `db.rs`,
  and `idx_device_pair_code` with it, replaced by `idx_device_pair_code_hash`. **Never re-add a
  `CREATE INDEX ... (code)` there** - the column does not exist, so schema init would fail on every
  startup. A test must confirm with **code only** (sending `sig` too would let a broken hash
  comparison pass, since either factor is accepted) and look up a **lowercase** code.
- **The session cookie's `Secure` flag is conditional, and must stay that way.**
  `AuthService::session_cookie()` adds `Secure` only when the request arrived over TLS
  (`X-Forwarded-Proto: https`, which Caddy sets and overwrites). It **cannot** be unconditional:
  the LAN path is plain HTTP (`http://192.168.1.16:8000`), and a browser refuses to store or send
  a `Secure` cookie over plain HTTP — so an unconditional flag breaks LAN sign-in entirely.
- **The pairing signature must never be keyed by a published constant.** `hmac_pair_code` read
  `MEDIA_SERVER_SECRET` while the deployment sets `MEDIA_SERVER_SECRET_KEY`, so it was silently
  using the literal fallback string published in the source. It now reads either name and falls
  back to a **random process-local key**, never a known constant.

### Device ownership & watch-history scoping (Phase 2, `rust/src/services/device_service.rs` & `rust/src/routes/devices.rs`)

`devices.user_id` (nullable, `ON DELETE SET NULL`, indexed by `idx_devices_user`) records which
account a physical client belongs to. It scopes the device list and its embedded watch history, and
it authorises renaming and deleting a device. The media library itself stays public — this scopes
*devices*, not media.

- **The column is additive and nullable, and that is the whole migration.** `NULL` means unowned: a
  guest device, or every row written before Phase 2. No row was rewritten and no backfill was needed.
  `ON DELETE SET NULL`, never `CASCADE`: deleting an account must unlink its devices, not delete the
  physical client's row and (through `device_watch_history`'s FK) the history beneath it.
- **Ownership is claimed exactly once, by the first signed-in devices request from that device.**
  The claim points are `GET /api/devices`, `/api/devices/heartbeat`, `/api/devices/client-hints`,
  and the rename/delete handlers (each claims the device the request came from). `claim_device_for_user`
  is `UPDATE ... WHERE device_id = $1 AND user_id IS NULL` — one conditional
  update, so it is atomic and a second account signing in on the same browser cannot take the device
  over. Never "reassign on sign-in": that would hand a device and its history to whoever loads the
  app next. `device_owned_by` is the read side, used by rename/delete.
- **The list is scoped in SQL, not filtered in memory.** Admin (PIN **or** admin session) sees every
  device; a signed-in caller sees the devices they own plus the device they are using; an anonymous
  caller sees only the device they are using. Do not restore a `devices.retain(|d| d.is_current)` for
  signed-in users — that was the Phase 1 behaviour and it hides a user's other devices.
- **Watch history follows *ownership*, not visibility.**
  A caller may read history for the devices they own and for unowned devices. A device owned by
  somebody else is still *listed* when it is the caller's current device (they are physically using
  it), but its `watch_history` is **empty**. That is the deliberate answer to a shared browser: the
  device is visible, the other account's viewing is not. A signed-out session on a claimed device
  therefore shows the device and no history.
- **Rename/delete authorisation is current device OR owned device; admins are unchanged.** A signed-in
  user may rename a device they own while using a different one, and a refused request is a **403
  whose target row must still exist**. Anonymous callers keep the original current-device-only rule.
- **`progress` (the legacy filename-keyed table) stays global, deliberately.** It is only consulted
  when a request carries no device id. Scoping it is tracked debt, not an oversight: the scoped
  history is `device_watch_history`, and that is the one the device list reads.
- **The Flutter contract is unchanged.** `/api/devices` keeps its shape — scoping changes *which*
  rows are returned, not the fields. `scripts/probe_android_api.py` remains the gate.

### Admin oversight of accounts, devices & watch history (Phase 3, `rust/src/routes/admin.rs` & `web/src/features/devices/DevicesPage.tsx`)

Phase 2 made ownership and history *sticky*: a device is claimed once and never reassigned, and a
watch-history row is never editable. Phase 3 is the supported, auditable way to correct both. It is
**oversight of what already exists — it adds no new scoping and shifts no visibility boundary.**

- **Owner attribution is admin-only, and that is the privacy boundary.** `GET /api/devices` carries
  `owner: {id, email, name, role}` for an admin (Admin PIN **or** admin session) and `null` for
  every other caller. The LEFT JOIN is attribution; the WHERE clause is Phase 2's scoping and must
  not widen. A viewer's payload must never contain another account's address — asserted in Rust and
  in the live smoke, never inferred from the UI.
- **`GET /api/admin/users` is the admin probe.** It answers 200 only for an authorised caller and
  lists `id, email, name, role, created_at, last_login_at, device_count, history_count`. It never
  returns `google_sub` (an identity key the UI does not need), and a viewer gets **403, not an empty
  list** — an empty list would be indistinguishable from a working route.
- **Reassignment is the one explicit exception to claim-once.**
  `POST /api/admin/devices/assign` takes `{device_id, user_id|null}`. A **missing** `user_id` is a
  400 — an explicit `null` is what unassigns, and `Option<Option<i64>>` plus a custom deserializer is
  the only serde shape that keeps "absent" and "null" distinct (plain `Option<T>` collapses them).
  An unknown device or user is a 404. The automatic claim stays `UPDATE ... WHERE user_id IS NULL`,
  so merely signing in still cannot take a device over. Ownership scopes history, so the history
  moves with the device; the confirmation says so before it happens.
- **History deletion touches history only.** `POST /api/admin/devices/history/delete` takes
  `{device_id, filename?}`: a filename deletes one row and a miss is a 404; omitting it clears the
  device's history (idempotent, `deleted: 0`). It deletes from **`device_watch_history`** and never
  from the legacy filename-keyed `progress` table, and no media file is read, moved or deleted.
- **Both mutations are admin-gated and the refusal is real.** Viewer and anonymous callers get 403,
  and the test asserts the target row is unchanged afterwards — a 403 that had already mutated state
  is not a refusal.
- **The web UI unlocks on server confirmation, not on a local flag.** A stored PIN or an admin role
  triggers `GET /api/admin/users`; only a 200 renders the Accounts panel, owner badges, owner filter,
  reassign modal and clear-history controls. A stale PIN therefore hides the controls instead of
  offering actions the server will refuse, and an ordinary viewer never sees them. Every modal is
  portaled to `document.body`.
- **No position editing, no account creation or deletion, no role changes, no library gating.** Those
  are deliberately out of Phase 3; the media library itself stays public (gating it would break
  DLNA/cast/device tokens).
- **The Flutter contract is unchanged.** `/api/devices` gains exactly one additive key, and the new
  routes are outside the client's surface. `scripts/probe_android_api.py` remains the gate.

### Public ingress invariants (Airtel Zyxel AOT5222ZY + Caddy)

- **Only 443 and 80 may be forwarded from the internet.** The origin must not be reachable over
  plain HTTP — that bypasses TLS, and the `session_token` cookie, entirely. A `8000` forward
  existed from 2026-10-19 and was removed on 2026-10-20.
- **The router's `delnum` is ZERO-BASED.** The table displays 1-based row numbers, but
  `deleteClick(0)` is the *first* rule. Sending the displayed number would delete the wrong rule —
  on this router, the **HTTPS** rule, taking the public site down. Use
  `scripts\router_port_forward.ps1`, which identifies a rule by its *content* and only then acts on
  the index, and which re-reads the table afterwards to confirm the other rules survived.
- **This router emits malformed HTTP headers** (bare CR). `Invoke-WebRequest` rejects them as a
  protocol violation; `curl.exe` tolerates them. The router script uses curl.
- **The router's CGI is undocumented.** Take a config backup before changing it; the tooling in
  `D:\Airtel xstream fiber` can download and decrypt one.

## 5. Platform/dependency rules

### Windows
- Windows 10/11 or supported Windows Server.
- Rust 1.85+ (MSRV 2021 edition), Cargo.
- Node.js 20+ & npm for `web/` React SPA.
- PostgreSQL 18.4 (`MediaServerPG` Windows Service on port 5432).
- PowerShell, Git, FFmpeg and FFprobe.
- Production Server: **MediaServerRust** (native Rust Axum binary via NSSM).
- Remote access: **Caddy** (`MediaServerCaddy` NSSM service) on 80/443, proxying to `127.0.0.1:8000`. The Cloudflare named tunnel is decommissioned; Cloudflare is DNS-only for this hostname.
- Never use `os.kill(pid, 0)` to check process liveness on Windows; use Win32 API process status checking to avoid broadcasting `CTRL_C_EVENT` across the console group.
- Never use `os.rename()` across disk volumes on Windows; use `shutil.move()` with target collision pre-unlinking.
- In tests and cache audits, always resolve the cache directory dynamically.
- Prioritize the high-capacity secondary drive `D:` (`D:\Flicks`, `D:\Flicks\.archive`, `D:\Flicks\.uploads`, `D:\Flicks\.deleted`) for raw video files, upload staging, cold source retention, and deleted-source staging, preserving the primary fast SSD `E:` (`E:\MediaServer`) headroom for the application, database (`E:\pgdata`), active HLS streams, and preview thumbnails. `C:` holds only the resilient service wrappers and binaries (`C:\MediaServer`, `C:\postgres`), not media or transcode data.
- All media path, cache lookup, and subtitle delivery routines must resolve across configured media roots.
- **Mandatory User Notification on Service Restart**: Whenever native backend code (`rust/src/**/*.rs`) is edited and recompiled, or service configuration changes, instruct the user to restart the persistent Windows service by running `e:\MediaServer\scripts\restart_rust_service.bat` (or via elevated PowerShell `Restart-Service MediaServerRust`).
- **Verify a deploy by artefact timestamp, never by a health check alone.** After restarting `MediaServerRust`, confirm the *binary* is newer than the last source commit before claiming the code is live. A 200 from `/health` proves only that *some* build is running. Concretely: `Get-Item rust\target\release\media-server-api.exe | Select LastWriteTime` and compare against `git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M:%S'`.
- **Service hosting & resilience (do not regress):** NSSM lives at `C:\MediaServer\bin\nssm.exe` and PostgreSQL binaries at `C:\postgres` (data stays `E:\pgdata`), so both survive `E:` absence; `MediaServerPG` runs as NetworkService with restart-x3 recovery actions. NSSM restarts `MediaServerRust` and `MediaServerCaddy` within ~5s of a crash, and both have SCM restart-x3 recovery. Probe PG with a TCP connect to `127.0.0.1:5432`, never `pg_ctl status`. Repo `.ps1` files must stay pure ASCII.

### Linux/Kali
- Rust 1.85+, Node.js 20+, PostgreSQL 16+.
- **Python is tooling-only, not a runtime dependency.** The backend is native Rust, the frontend is
  a React SPA, and the database is PostgreSQL — none of them need Python to build or run. Python
  remains only for the operational probe and release scripts, and most of those are
  standard-library only. See `requirements.txt`.
- FFmpeg and FFprobe on `PATH`.
- Production: `media-server-api` systemd service.
- Remote access: Caddy TLS terminator on 80/443 (or a cloudflared named tunnel if that deployment uses one).
- Keep origin on `127.0.0.1:8000` when Cloudflare is the public front end.

## 6. Player invariants

- Direct streams must remain isolated from transcoding status/polling logic.
- Seeking must not synchronously assign `currentTime` on every seek-bar drag event; commit on gesture completion.
- During scrubbing or browser seek, `timeupdate` must not snap the slider back to an old timestamp.
- Direct MP4/AAC seeking and MKV/HEVC HLS seeking must both remain functional.
- Preserve player container isolation and mobile viewport clamping in React (`web/src/pages/PlayerPage.tsx`).
- `/api/media-info` reports the **video stream's end** as `duration` for HLS playback and the container duration for direct play: HLS timelines come from our playlist, while a direct-play browser reads the file's own metadata and must not be desynced. Any HLS completeness denominator (chunks, progress, ENDLIST) must likewise use the video end.
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
  treats the artifact as unseekable, so both our seeks and a phone scrub do
  nothing.
- **Volume goes on the `receiver` namespace, and it is the only volume control
  that works here.** `SET_VOLUME` on `receiver-0` moves this television's
  speakers and raises its on-screen indicator — verified by watching it. The
  media-namespace alternative with a `mediaSessionId` is accepted and echoed
  back while changing nothing audible.
- **The receiver's volume lives at `status.volume.level` and `status.volume.muted`,
  nested — not at `status.volume` as a scalar.** Reading it flat misses the field,
  and the documented fallbacks then report **100 and unmuted on every call**,
  which is indistinguishable from a receiver that reports no volume at all.
  pychromecast reads `status_data.get("volume", {})` then `.get("level")` /
  `.get("muted")`; the working Flask path reports exactly that as
  `cast.status.volume_level` / `volume_muted`. The media namespace also carries a
  per-session volume, but that is a value the app stores, so report the
  receiver's copy. **It is a real, working reading — do not conclude a field is
  "not exposed by the protocol" before checking you are reading the path the
  working implementation reads.**
- **Write fixtures from a captured payload, never from imagination.** Every
  accepted-and-ignored bug in this port was shielded by a unit test whose
  fixture had the *same* wrong shape as the code: the parser read `volume` flat
  and the fixture said `"volume":0.45`, so it passed against a payload the
  receiver never sends and the live read fell back to 100 forever. A test whose
  expected value was invented is not evidence. Capture the real message, paste
  it in, and assert against that — and where a fallback default exists, add a
  test that the real shape does *not* land on the default.
- **A field that is never found reports its default, not an error.** That is why
  every one of these failed silently. Prefer a missing field being visible over
  it resolving to a plausible value.
- **Mute is `SET_VOLUME` with a `muted` field — there is no `SET_VOLUME_MUTED`.**
  The wrong type is accepted with `ok: true` and does nothing, which reads as
  "this receiver has no mute". pychromecast (the working Flask path) sends
  `{"type": "SET_VOLUME", "volume": {"muted": ...}}`.
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
- **An absent or empty media `status` means stopped, not buffering.** An app
  that is running with nothing loaded is idle. Do not infer "buffering" from
  "the app is running" — the receiver reports `BUFFERING` explicitly, and the
  inference leaves a finished cast showing `buffering` forever.
- **Every reader of receiver `status` goes through `cast_proto::status_object`.**
  `MEDIA_STATUS.status` is a **list** on some receivers (`[]` while idle) and an
  object on others. Indexing it directly produced three separate bugs — a zero
  position on a playing cast, a refused `seek`, and a phantom "still playing"
  after teardown — and two of them read as "casting is broken" when casting
  worked. Keep the shape assumption in one function.
- **Live verification must tear down in a `finally`.** `scripts/verify_cast_live.py`
  starts playback on the real television; its `stop` cannot be skipped by an
  early return or a timeout, and it exits non-zero if the receiver is still
  playing. Never interleave code work between starting a cast and stopping it.
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
  idle blank receiver screen that reads as a hang. The quit message is
  **`{"type": "STOP", "sessionId": ...}`** on the `receiver` namespace —
  `STOP_APP` does not exist. See the standalone invariant below.
- **Quitting the receiver app is `STOP` + `sessionId`; there is no `STOP_APP`.**
  pychromecast, backing the working Flask path, sends `{"type": "STOP"}` with
  `inc_session_id=True`, which becomes `data["sessionId"] = status.session_id`.
  `sessionId` is read from `applications[].sessionId` in `RECEIVER_STATUS` — the
  same entry that carries `transportId`. `{"type": "STOP_APP"}` is accepted,
  answered, and leaves the app running on its blank screen while every layer
  reports success. This is the third instance of the accepted-and-ignored
  message type (`transportId`, `SET_VOLUME_MUTED`, `STOP_APP`); **diff a failing
  payload against a working client before concluding the device lacks the
  feature.**
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
# 1. Rust backend unit & integration tests
cargo test --manifest-path rust/Cargo.toml -- --test-threads=1

# 2. React frontend unit tests and production build verification
cd web
npm run test
npm run build
cd ..

# 3. Live client contract probe suites (against running server)
python scripts/probe_android_api.py
python scripts/probe_phase_8_contracts.py
```

Flutter client:

```powershell
.\scripts\run_flutter_tests.ps1
```

- **Run the Flutter suite through `scripts/run_flutter_tests.ps1`, never as a bare `flutter test`.** It purges media_kit's orphaned temp state before the run and again in a `finally`, which is what stops the accumulation. `NativeReferenceHolder` writes one reference-buffer address to `...NativeReferenceHolder.$pid`, creates that file empty before writing, and never deletes it; Windows recycles PIDs, so a new test process inherits a dead run's file and either `int.parse('')`s it (`FormatException: Invalid number`) or adopts a dead heap pointer via `Pointer.fromAddress`, hanging every `add()`/`remove()` that awaits the never-completed `_completer` — the whole file then reports "did not complete". Measured: 415 orphaned files (70 empty) spanning 2026-09-24..10-03 caused 2 failures in 6 runs *including one `--concurrency=1` run*, so serial is **not** a fix; after the purge, repeated full runs leave 0 stale files. The script also refuses to delete a file whose PID is a live process. Debug-mode only (`if (!kDebugMode) return;`), so release APKs and device playback are unaffected. Full analysis, and the rule not to re-add `MediaKit.ensureInitialized()` to tests that do not need native playback, are in `docs/FLUTTER_CLIENT_STATUS.md`.
- **Ordinary Flutter tests must never reach the live server.** `test/support/test_network_guard.dart` installs an allowlist `HttpOverrides` (per-isolate, so call it from each file's `setUp`/`setUpAll`, after `TestWidgetsFlutterBinding.ensureInitialized()`) that refuses any non-sentinel host, plus a shared sentinel origin `http://test.invalid:8000` — deliberately non-loopback, because `PlayerMediaResolver.resolveServerOrigin` skips loopback media hosts and would then fall through to the production `connectionControllerProvider`. Tests that genuinely need the running server stay behind `liveServerSkip` (`MEDIA_SERVER_LIVE_TESTS=1`) and must never null `HttpOverrides.global` unconditionally.
- **Run the Playwright harness with the GPU disabled, and never alongside a transcode.** This host's AMD graphics driver is chronically unstable — 42 queued WER kernel reports from September 2025 to October 2026, including 22 GPU TDRs — and on **2026-10-20 15:01 a hard system reset** was triggered by headless-Chromium GPU compositing during the brand-intro pixel oracle. `web/playwright.config.ts` now launches every browser with `--disable-gpu`; software rasterisation is deterministic, which is what a pixel oracle needs anyway, and the oracle still passes 5/5 with it. **A transcode and the Playwright harness must never run at the same time** — both are GPU-heavy, and that is how a TDR becomes a hard reset. The full post-mortem is in [`Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md`](Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md); the finding is Issue 13 in [`docs/Current issues.md`](docs/Current%20issues.md).
- **The Playwright harness needs the Vite dev server — and only while it runs.** `web/playwright.config.ts` sets `reuseExistingServer: true`, so the harness reuses a dev server if one is listening on `http://localhost:5173` and **starts one itself if none is**. So the rule is: **start it when you are about to run the web oracles, and stop it when you are done with them** — `cd web; npm run dev 2>&1` in the **background** (so it does not block), and stop the `vite` process when the run is over. It is a tool for the oracles, not a standing service: the brand-intro oracles need it (`web/e2e/intro-frame.spec.ts` drives the archived original from `web/e2e/intro-harness.html`, and `web/e2e/intro-audio.spec.ts` renders the score through the dev server's module graph), and **nothing else does** — not the Flutter suite, not the Rust backend, not the fixtures. **Note the host:** the dev server binds the **IPv6 loopback** (`::1`), so reach it at `http://localhost:5173` and not at `http://127.0.0.1:5173`.
- **The dev server's API has ONE origin, and it is `:8000`.** The Rust service is the whole server — the Flask backend is decommissioned (Phase 7E) — so every proxied prefix goes to `http://127.0.0.1:8000`. The configuration used to point its "Rust" routes at `:8001` (where nothing runs) and its "Flask" routes at `:8000` (which *is* the Rust service): the two were **the wrong way round**, and every `/api/movies` call through the dev server failed with `ECONNREFUSED` while filling the log. **`:8001` is the *injection proxy's* own port** (`docs/opening-sequence/scripts/serve_with_intro.py`, which forwards to the app on `:8000`) — it is not a retired backend, and the archived tooling is consistent about it.
- **Never let a long command block indefinitely.** Anything that can take minutes — a Flutter suite, a Playwright run, a build, a frame capture — goes to the **background** with an explicit timeout, and the agent **checks it on an interval** and reports its state rather than waiting on it forever. A foreground command with no bound is how a session appears to hang; a bounded wait with a status line is how it does not.

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

### Client API Contract Stability

The shipped Flutter app (`flutter_client/`) is an active client and must keep working seamlessly.
Its entire server surface is `/api/*`, `/media/`, `/hls/`, `/subtitles/`, `/poster/*`, `/tmdb-poster/`, `/tmdb-backdrop/`.

Verify after any API or routing change:

```powershell
python scripts/probe_android_api.py    # 22 endpoints, live server, exit 1 on break
```

Its expectations are each route's *contract*, not a wish for `200`: `/api/app/*` answers
`404` when nothing is published for the channel, and `/api/cast/status` answers `400` when
no cast is active. Both are working routes; `CastRepository.status()` catches the
`DioException` and returns `null`, so polling while idle is normal. Do not "fix" those
into `200`s — that would be changing a documented behaviour to satisfy a bad probe.

- **Axum SPA Route Fallback Invariant:**
  In `rust/src/main.rs`, the React SPA is hosted with static file serving from `web/dist/` and an
  Axum fallback handler returning `web/dist/index.html` for client-side routing. All `/api/*`,
  `/media/*`, `/hls/*`, `/subtitles/*`, `/poster/*`, `/tmdb-poster/*`, `/tmdb-backdrop/*`, and `/auth/*`
  routes are registered first on the router to guarantee they are never shadowed by the SPA fallback.

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

- **Native Independence Invariant (Zero Proxy Shims):**
  The backend is 100% native Rust Axum. All proxy bridges and interim delegations to the legacy Flask backend have been completely decommissioned. All features (e.g. gzip decompression via `flate2`, HTTP queries via `reqwest`, media probing via `ffprobe`, container extraction via `ffmpeg`) execute 100% natively in Rust.
- **Database Test Isolation & Teardown Guardrail:**
  Any test suite or harness in Rust or Python that inserts test movie or progress rows into `media_server` (PostgreSQL 18.4 — the only production database; the SQLite `media.db` was retired in the Phase 3 migration and no longer exists) MUST clean up lingering test records during setup (e.g. `DELETE FROM movies WHERE filename LIKE 'rust_test_movie_%'`), implement an explicit teardown hook (`harness.teardown().await` or fixture cleanup) deleting test rows, and guarantee zero phantom test movies remain in development or production databases.
  - **The Rust integration suite must not touch the production database at all.** `AppConfig::from_env()` falls back to `postgresql://postgres:postgres@127.0.0.1:5432/media_server` when `MEDIA_SERVER_DATABASE_URL` is unset, which it is on this host — so a test built on `from_env()` writes to the live catalog. Use `media_server_api::test_support::test_config().await` instead: it provisions a dedicated `media_server_test` database (override with `MEDIA_SERVER_TEST_DATABASE_URL`), redirects `cache_dir` to a temp path, and leaves `media_roots` alone so file-based contracts still work. `media_server_api::test_support::seed_real_media_row()` seeds a catalog row for a real, probeable file when a test needs one, and `remove_seeded_media_row()` removes it again.
  - **A test that inserts rows must be idempotent and must clean up on the way out.** A plain `INSERT` of a fixed key passes once and then fails forever with `23505 duplicate key value violates unique constraint`. Use `ON CONFLICT ... DO UPDATE` for the insert *and* a setup-time purge *and* an explicit teardown.
  - **`Drop` cannot clean a database.** It is synchronous; the database calls are async. A teardown hook has to be an `async fn` the test calls, and the test should then assert the residue count is zero rather than trusting the hook.
  - **Do not assert against production data.** A test that hardcodes a library title breaks when that title is removed. The `scanner_engine` reconciliation test used to assert that `Oculus.2013.1080p.BluRay.x264.YIFY.mp4` survived; it now owns its fixture.
- **Axum Wildcard Routing & Internal Prefix Dispatcher:**
  Axum's radix router strictly forbids overlapping wildcard parameters under the same parent prefix (e.g. `/subtitles/{*path}` and `/subtitles/embedded/{*path}`). Multi-mode stream handlers must register a single wildcard endpoint (e.g. `/subtitles/{*path}`) and dispatch internally using string prefix matching (`clean.strip_prefix("embedded/")`, `clean.strip_prefix("online/")`) before falling back to local files.
- **Recursive Media Path Resolution Fallback:**
  Media files referenced by bare filenames across subdirectories must resolve safely across media roots using bounded recursive search in `PathResolver::resolve_media_path`, preserving strict directory traversal (`..`) security defenses.

