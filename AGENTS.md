# Agent Instructions — Anis' Media Server

## 1. Project identity and source of truth

- Repository: `anis7t/media-server`
- Framework: **Flask**, not Django.
- The application is modularized under `app/` with routes, services, utilities, configuration, and database layers.
- Root `app.py` is intentionally a lightweight executable entry point; `app/__init__.py` owns the application factory and compatibility exports.
- `docs/PROJECT_STATUS.md` is the primary current handoff: it records completed work, known bugs, platform requirements, testing requirements, and the immediate work queue. Read it before substantial changes.
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


## 4. Known unresolved issues & active roadmap

### Highest priority — immediate work queue

1. **Production concurrency tuning & remote streaming benchmarks:**
   Benchmark Waitress worker and thread pools against remote stream latency, Cloudflare tunnel limits, and concurrent client playback.

### Secondary / parked

4. **Automatic OpenSubtitles behavior:** local subtitles work; incorrect automatic OpenSubtitles behavior is parked.
5. **Authentication/access control:** the stable Cloudflare hostname is not authentication. Add access control before wider public sharing.
6. **Cloudflare media-delivery architecture:** review current Cloudflare service-specific video/large-file policies before treating the public tunnel/CDN path as a scalable distribution system.
7. **Production concurrency tuning:** benchmark any change to worker or thread pools. Remote capacity is primarily constrained by ISP upload bandwidth and tunnel/network latency.

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
- Cast status is read from the receiver (`/api/cast/status` → `state`, `position`, `duration`), so it is
  the ground truth for "did the TV actually move?" — never infer it from the phone's UI.

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
  - **`_finalize()` records the accepted shortfall** to `hls.loss.json` (frames, seconds, chunks, both
    thresholds, timestamp, reason) when it seals a short cache. Not into `hls.progress` — that is ffmpeg's
    own `-progress` file.
- **Never call `source_video_duration(path, fallback=<anything but None>)`.** Any non-`None` fallback
  disables that function's own container-duration fallback, so a title whose video end cannot be measured
  returns a hard `0`; `plan_chunks(0)` is then `[]` and the cache is judged **vacuously complete**. Use the
  bare call. This silently skipped 28 Weeks Later in `hls_restore_endlist.py`, and every such title in
  `hls_frame_audit.py`.
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
- `tests/conftest.py` owns test isolation: it redirects the cache, database, upload target/staging, archive and deleted directories onto a throwaway tree **through the environment before the app is imported** (so a `config` reload recomputes throwaway paths), re-asserts them before every test, and refuses any deletion inside the checkout's `cache/` tree. Never rely on import-time attribute rebinding alone: `tests/test_app.py`'s teardown reloads `app.config` and `tests/test_selenium_multi_seek_coyote.py` rebinds `app.CACHE_DIR = app.config.CACHE_DIR` — that is how a full-suite run once deleted the live transcode cache. `audit_orphaned_caches()` derives the "active" set from `video_paths()`, so any run whose cache is not isolated makes every real HLS directory look orphaned and the non-dry-run purge deletes production transcodes; likewise, `_resolve_upload_dirs()` returns `MEDIA_ROOT` under pytest, which once wrote 22-byte fixtures into the real library and fixture rows into the production database.
- Verify isolation the hard way after touching it: snapshot the library file list, the production `movies` rows and the `cache/hls` directory list (plus a hash of each) before and after a full run — all three must be unchanged.
- The orphan audit is fail-closed by design; do not reintroduce bare `except Exception: <empty active set>` handling around media enumeration.
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
