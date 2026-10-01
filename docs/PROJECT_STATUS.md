# Project Status, Completed Work, Bugs & Hosting Requirements

Last reviewed: 2026-09-30
Repository: `anis7t/media-server`
Working branch: `feat/flutter-production-player`

---

## Flutter Client Migration (active — read before touching `flutter_client/`)

Full handoff document: **[`docs/FLUTTER_CLIENT_STATUS.md`](FLUTTER_CLIENT_STATUS.md)**

| Phase | Title | Status |
|-------|-------|--------|
| 1 | Flutter Client Foundation | ✅ Committed (`5b0b1fa`, `eadb257`) on `feat/flutter-player-poc` |
| 2 | Video Player POC | ✅ COMPLETE — All 6 stages (2A–2E + 2F Acceptance Report) PASS on LAN & WAN (`f8e8c23`) |
| 3A | Production Player Architecture | ✅ COMPLETE — Committed on `feat/flutter-production-player` |
| 3B | Android-First Timeline & Live Seek Preview | ✅ COMPLETE — Committed (`2e95246`) |
| 3C | Audio & Subtitle Track Selectors, Speed & Controls Polish | ✅ COMPLETE — 58/58 tests passed, zero analyzer issues |
| 4.1 | Library Data Layer & API Endpoints | ✅ COMPLETE — API contracts frozen |
| 4.2 | Library UI, Movie Card Grid, Continue Watching Rail | ✅ COMPLETE — physical device verified |
| 4.3 | Library Search, Sort, Filter | ✅ COMPLETE — debounced search, 3 sort modes, genre filter |
| 4.4 | Movie Details Screen & Direct Playback Handshake | ✅ COMPLETE — details → play → back flow verified |
| 4.5 | Multi-Channel Distribution & In-App Update Architecture | ✅ COMPLETE — update subsystem operational |
| 4.6 | Persistent Bottom Navigation & Settings Integration | ✅ COMPLETE — 3-tab shell (Home, Library, Settings), device-verified; 143 passed / 10 skipped (live-server tests opt-in) |
| 4.7 | Fire TV & Android TV 10-Foot Experience (Universal APK) | ✅ COMPLETE — Single universal APK (`in.anisparvez.media_server_client`) for Mobile & TV. Runtime capability detection, collapsible obsidian side rail (`TvSideNavigationRail`), borderless fullscreen TV player, autofocus action triggers, D-pad remote navigation, physical Fire TV Stick 4K (`AFTMM`) & Vivo mobile verified |

---

## 0. Recent work

### 2026-10-02 — Playback Overlay State Management (Phase 4 Complete)

**Deliverable:** Resolved clashing, stacked, and lingering playback status overlays on the video canvas (Issue 3). Unified independent boolean layers (`isOpening`, `_isBuffering`, `_isHudVisible`, Center Play/Pause) into a single, mutually exclusive state model:
1. **`PlaybackOverlayStatus` & `PlaybackOverlayType`:** Created a dedicated domain model (`none`, `opening`, `buffering`, `seeking`, `toast`) with deterministic priority ordering: user-initiated actions (`seeking` / `toast`) take precedence over background stream states (`opening` / `buffering`).
2. **Buffering Suppression During Seeking:** While the user is actively seeking (remote D-pad Left/Right, media keys Rewind/Fast-Forward), the "Buffering Stream" loading indicator is suppressed, displaying only the seek feedback pill and eliminating stacked cards. If buffering persists after the 1000ms seek settle window, it transitions smoothly to "Buffering Stream".
3. **Accumulated Seek Delta:** Rapid successive seek inputs accumulate delta (`+10 sec` → `+20 sec` → `+30 sec`) and refresh the settle timer in a single unified HUD toast.
4. **Center Play/Pause Suppression:** Passed `isOverlayActive: overlayStatus.isVisible` to `PlayerControlsOverlay`, preventing center play/pause collision with active toasts or seek indicators.
5. **Timeline Scrubbing Protection:** Suppressed buffering indicator while user is actively scrubbing the timeline scrubber.
6. **Automated Verification:** Added 13 unit and widget tests in `test/features/player/player_overlay_state_test.dart`. All 102 player tests and 261 total client tests pass with 0 static analysis issues.

### 2026-10-02 — Android TV & Fire TV Player Back Behaviour (Phase 3 Complete)

**Deliverable:** Resolved the TV Back button regression during video playback where pressing Back immediately terminated playback and exited to library/details. Re-established the intuitive 2-step TV remote transport model:
1. **First Back Press (Controls Hidden):** When controls are hidden during active playback, pressing Back (`LogicalKeyboardKey.escape`, `LogicalKeyboardKey.goBack`, or Android OS `PopScope`) reveals the player controls, resets the auto-hide timer, restores player focus to the timeline scrubber (`_tvFocusZone = TvPlayerFocusZone.timeline`), and consumes the event without stopping playback or exiting.
2. **Second Back Press (Controls Visible):** When controls are already visible, pressing Back executes the standard player exit lifecycle: cancels timers, flushes/disposes watch progress, stops the media controller, and pops the player route cleanly.
3. **Removed Force-Exit Bypass:** Eliminated `forceExit: isTv` from `PopScope` and `onHandleBack(forceExit: true)` from `PlayerKeyDispatcher` when controls are hidden. All 248 Flutter tests pass with zero analyzer issues.

### 2026-10-02 — 2D Weighted Spatial Focus Traversal Policy (Phase 2 Complete)

**Deliverable:** Fixed intermittent D-pad Up/Down navigation skipping where visually adjacent focusable elements were bypassed due to Flutter's default 1D band-culling in `DirectionalFocusTraversalPolicyMixin`.
1. **`TvSpatialFocusTraversalPolicy`:** Created a custom 2D directional traversal policy (`lib/core/navigation/tv_spatial_focus_traversal_policy.dart`) implementing weighted vector scoring (`score = Δprimary * 4.0 + Δorthogonal * 1.0 + Δalign * 0.25`) with a 60% row/column visual overlap gate.
2. **App-Wide Registration:** Attached policy to `MediaServerApp` root builder in `app.dart` and `tvContentFocusScopeProvider` in `app_shell.dart`. Upgraded preset server chips in `connection_screen.dart` to `TvFocusable`. All spatial focus tests pass.

### 2026-10-01 — Fire TV Stick 4K Hardware Playback Hardening & Driver Lock Prevention

**Deliverable:** Resolved low-level MediaTek Display Processor (MDP) kernel fence deadlock and PowerVR GE9215 GPU desynchronization on Amazon Fire TV Stick 4K (`AFTMM`), enabling zero-stutter hardware-accelerated playback across all standard and non-16-byte-aligned video files (e.g. *Scary Movie* at 1916×800) alongside automatic dynamic software decoding (CPU fallback).

**Key Architectural Changes:**
1. **`mediacodec-copy` Decoupled Pipeline:** Configured `VideoControllerConfiguration(hwdec: 'mediacodec-copy')` on Android in `MediaKitPlayerAdapter`. By copying decoded frames rather than sharing raw zero-copy `SurfaceTexture` hardware buffers with EGL, PowerVR texture inconsistency (`E IMGSRV : IsTextureConsistent: IMGEGLImage is not consistent`) and MediaTek MDP fence lockups (`E MDP : wait input fence[353] timeout`) are eliminated completely.
2. **Dynamic Software Fallback (`fallbackToSoftwareDecoder`):** If hardware decoding encounters any driver errors or if the first video frame is not rendered within 4 seconds (`_firstFrameRendered` tracking via `videoController.waitUntilFirstFrameRendered`), the adapter dynamically sets `hwdec: 'no'` (libavcodec CPU decoding) and flushes decoder buffers via a position seek without interrupting audio or requiring an app restart.
3. **Broadened Driver Error Keyword Detection:** Catch and recover from `video`, `codec`, `mediacodec`, `vd`, `decoder`, `hwdec`, and `surface` errors from the mpv stream error dispatcher.
4. **Physical Verification:** Verified full-screen hardware-accelerated video playback on physical Amazon Fire TV Stick 4K (`192.168.1.70:5555`) with *Batman: Knightfall* (1920×1080) and *Scary Movie* (1916×800) with zero dropped frames. Built and deployed APK `1.2.12` (build 132). Unit tests: 205 passed, 0 analyzer issues.

### 2026-10-01 — PlayerScreen Architecture Segregation & Modularization (2,283 → 1,232 lines)

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

### 2026-10-01 — Fire TV Stick 4K & Android TV (Pass 2 Refinements: Focus Traversal, Debounced Exit & 10-Foot Leanback UI)

**Deliverable:** A polished second-pass leanback experience on the universal Android APK (`in.anisparvez.media_server_client`), hardening D-pad remote navigation, edge-to-rail focus transitions, exit confirmation debouncing, and TV Settings UI on physical Amazon Fire TV Stick 4K (`AFTMM`) connected to a 4K TV.

**Key Architecture & Invariants:**
1. **Debounced Double-Back & Root Exit Focus Trap:** Converted `TvExitDialog` to a stateful dialog with an internal `_isShowing` static guard, `barrierDismissible: false`, and a 350ms dismissal gate (`_canDismissOnBack`). In `AppShell._handleBack()`, implemented a 350ms timestamp debounce (`_lastBackTime`), resolving twin-event dispatch from physical TV remotes (key down + activity pop route). Default focus is locked to "Cancel" in obsidian glass with red glow; D-pad Right navigates to "Exit". Back press while dialog is open safely cancels without quitting.
2. **Directional Traversal Bridge (`TvDirectionalFocusAction`):** Content area in `AppShell` is wrapped in a custom `DirectionalFocusAction`. When pressing D-pad Left at the leftmost column of any content screen (e.g., column 0 of "Continue Watching", "All Movies" grid, or Settings), the action intercepts the boundary traversal, collapses any in-flight content focus, shifts focus directly to the active rail item (`tvRailFocusNodesProvider[currentIndex]`), and expands `TvSideNavigationRail` smoothly.
3. **Rail-to-Content D-pad Right Restoration:** Navigating D-pad Right from an expanded rail item collapses the rail back to 68dp and restores focus cleanly to the first visible content card without losing scroll position. Removed `escape` and `goBack` overrides from rail items so physical Back keys bubble unconditionally to `AppShell`.
4. **TV Settings 10-Foot Architecture:** Stripped redundant top logo/subtitle on TV (`!isTv`), displaying a single clean "Settings" heading. Transformed Server Connection, Device ID, and Update Channel into full-width focusable cards with glowing borders. Wrapped `Switch.adaptive` in `ExcludeFocus` to prevent trapped focus on non-interactive toggle controls.
5. **TV Remote Player Polish:** Bound 2-zone remote transport model; D-pad Up/Down volume manipulation was eliminated to avoid conflicting with TV hardware CEC volume and vertical navigation.
6. **Automated Verification:** 99/99 shell and player tests passed, 47/47 library tests passed, 0 analyzer issues across `flutter_client`.

### 2026-09-30 — Fire TV Stick 4K & Universal Android APK (10-Foot Leanback UI)

**Deliverable:** A single universal APK (`in.anisparvez.media_server_client`) operating seamlessly across both Android mobile phones (touch UI + persistent bottom navigation + portrait player) and Amazon Fire TV Stick 4K / Android TV (10-foot D-pad remote UI + collapsible obsidian side rail + borderless fullscreen cinema player). Zero separate APKs, zero Android product flavors.

**Key Architecture & Invariants:**
1. **Device Capability Model:** Runtime detection via native platform channel (`in.anisparvez.media_server_client/device_mode`) in `MainActivity.kt` inspecting `android.software.leanback`, Amazon Fire TV model signatures (`Build.MODEL.startsWith("AFT")`), UI mode type (`Configuration.UI_MODE_TYPE_TELEVISION`), and absence of touch screen. Exposes `deviceCapabilitiesProvider`, `isTvModeProvider`, and `isFireTvProvider`. Includes a debug "Force TV UI Mode" switch in Settings for phone/tablet testing.
2. **TV Navigation Shell:** Collapsible obsidian left rail (`TvSideNavigationRail`, 68dp collapsed / 220dp expanded) with brand-red glowing focus pill and D-pad navigation. Replaces mobile bottom navigation completely on TV (`isTv == true`).
3. **10-Foot Cinema Details:** Two-column 16:9 layout on TV with poster/specs pills on left and title/synopsis/cast on right. Primary action ("▶ Resume" or "▶ Play Movie") is autofocus-highlighted in brand red (`autofocus: true`), enabling instant one-click playback upon opening any movie details.
4. **TV Fullscreen Player & Remote Transport:** Video player automatically enforces 100% borderless fullscreen on TV, eliminating portrait split view. Redundant Cast and Fullscreen buttons are completely hidden on TV. Back key state machine dismisses controls overlay first if visible; otherwise flushes progress and returns to Movie Details. D-pad Center, Up/Down (volume), Left/Right (seek ±10s), Play/Pause, Rewind/Fast Forward keys mapped for remote responsiveness.
5. **Physical Device Verification:** Built release APK (97.3 MB) and installed on physical Amazon Fire TV Stick 4K (`AFTMM` on `192.168.1.70:5555`) connected to a 4K Samsung TV. Tested D-pad navigation, card focus, details autofocus, and fullscreen playback of *Batman: Knightfall*. Installed identical APK on physical Vivo phone (`192.168.1.13:38595`), confirming 100% preservation of mobile touch UI and bottom bar.
6. **Automated Verification:** 233/233 tests passed, 0 analyzer issues across entire repository.

### 2026-09-30 — Opening sequence (brand sting): delivered, wired, and prompt-free autoplay

**Deliverable:** a 3.00-second branded opening — build-up → logo impact → two-note motif → wordmark →
curtain — for the server, with an original synthesized score (no samples, nothing licensed). The outro
is an **overlay over the running app**: when the curtain parts what is revealed is the app's own page,
already loaded and already interactive — its header, its posters and its live telemetry, not a copy of
them.

**Prompt-Free Autoplay & In-App Integration:** Delivered and wired into the app. The click-to-start `#gate` prompt card ("Play with sound") was eliminated so the animation runs fully and automatically upon entry without requiring user clicks (`mode = 'auto'`). `#gate` is hidden by default and preserved solely for explicit manual testing (`?intro=gate`). Web Audio API playback starts immediately with transparent one-time interaction listeners (`pointerdown`, `keydown`, `touchstart`) to resume suspended audio contexts without delaying visual playback. The overlay is gated once per browser session via `sessionStorage` in `templates/library.html`, and `?intro=off` cleanly omits all overlay DOM nodes in Jinja. Artifacts reside in `docs/opening-sequence/`. Full detail in [`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md).

**Android Mobile Client Opening Sequence (Flutter):** Delivered to the Android Flutter client (`flutter_client/`). Bundled the synthesized 1080×1920 portrait MP4 ident (`assets/videos/intro-demo-portrait.mp4`), implemented Riverpod `IntroController` (`IntroState` session gating once per app launch), edge-to-edge `BrandIntroOverlay` with `media_kit` hardware video & audio decode, tap-anywhere / skip pill dismissal with 300ms fadeout, and unconstrained underlying `AppShell` mount. Added "Replay Brand Intro" control in Settings (`SettingsContent`). Passed full test suite (210/210 passed, 0 analyzer issues), compiled `v1.2.2+122`, and installed & launched on connected Vivo I2217 (Android 16).

**Verification:** `verify_overlay.py` — 12 behavioural checks against the running server, all pass: the
app's DOM is present under the layer (12 cards, 11 posters), the AudioContext reaches `running` on a real
click, the veils cover the app at 1.35 s, the layer removes itself by 3.2 s, **a real click afterwards
reaches the app's own search field**, capture mode stops the app's clock, and the 0.25 s tail hold is
byte-identical while the sequence itself is not. Both rendered videos `ffprobe` at 90 frames and
`duration 3.000000` with a real AAC track (RMS −18.88 dB, peak −3.08 dB).

**Three defects found and fixed while rebuilding:** the capture mode was filming the click-to-start gate
instead of the sequence (90 identical frames); the layer's `html,body` CSS was overriding the app's body
background and stopping its scrolling; and `Emulation.*` needs a page session before it can set a
viewport. The capture/render lessons that generalise are recorded in §8 of the doc.

### 2026-09-28 — Casting to DLNA TVs and Chromecast (web player + Android app)

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
  the position for the whole cast. Its label separator had been double-encoded as `Â·` on the app side -
  fixed, and a widget test (`player_cast_bar_test.dart`, 3 cases) pins the label rule.

**Verification:** `tests/test_cast_api.py` (44) and `tests/test_cast_dlna_integration.py` (6, driving
the real SOAP flow against a stub UPnP renderer that mimics the TV's faults); server suite
**296 passed / 1 skipped**, Flutter **197 passed / 12 skipped**; `node --check` clean on the rendered
player script. Live discovery found the real TV: `UA43DU7000KLXL` at 192.168.1.8 with AVTransport +
RenderingControl, announced as a Cast device too.

**Hardware acceptance (real Samsung DU7000):** discover → cast → the TV reports `playing` with its own
position advancing → pause → play → volume → stop, all with `last_error` empty. Two hardware-only
defects were found and fixed in the process:

- **SSDP left the wrong interface.** This host is dual-homed (Ethernet 192.168.1.16, Wi-Fi 192.168.1.12
  plus link-local virtuals) and an unbound multicast socket took the OS default route — the M-SEARCH
  went out over Wi-Fi and discovery found nothing, even though the TV answered a ping and its DLNA
  description on the Ethernet address. `discover_dlna()` now sends from every usable IPv4 interface
  (`_multicast_interfaces()`, loopback/link-local excluded), which finds the TV immediately.
- **A Seek sent before Play aborted the entire cast.** The renderer answers UPnP **701 (Transition not
  available)** to a seek while its transport is stopped; the old `SetAVTransportURI → Seek → Play`
  order therefore 500'd and the load never started, so casting with a resume point silently did
  nothing. The order is now `SetAVTransportURI → Play → (wait for transport) → Seek`.
- **This TV refuses Seek altogether** (701 on every form — `REL_TIME`, `ABS_TIME`, `REL_COUNT`; it does
  not accept `SeekMode` either, answering 402), so a cast on this model starts at the beginning and its
  own remote is needed to jump. Chromecast handles seek natively, so that path is unaffected. UPnP
  faults are now translated (`UPNP_FAULTS`) instead of surfacing as a bare "HTTP 500" — 701 reads
  "This TV does not allow seeking from another app - use its own remote to jump ahead." 

**Live means now:** the /api/cast/* endpoints run against the real TV from the owner's restarted
service (192.168.1.16:8000) — discovery locates `TV (UA43DU7000KLXL)`, /api/cast/play hands it the
media and the TV reports `buffering` → `playing` with its own position advancing, /api/cast/stop ends
it. The app's picker lists the TV, clicking it plays, the cast bar appears (`TV · Starting…` → `TV · 0:01`)
and its stop button ends the cast; the cast button itself shows `is-casting`. The web player does the
same on both surfaces, through the live API.

### 2026-09-28 — Player swipe controls (volume & brightness) + progress persistence (`a0877ce`)

**Gestures:** swiping up/down on the video surface drives the phone's own levels — **left half =
brightness, right half = system media volume** — with a HUD readout (`N% Brightness` / `N% Volume`).
A full-height swipe covers the whole range; the value at drag start is captured and the drag
fraction is applied as an offset, so the mapping stays absolute however many events arrive.

- Vertical drags are **opt-in** on `DoubleTapSeekDetector` (`onVerticalDragBegin/Delta/End`): a drag
  never satisfies the tap (toggle controls) or double-tap (seek ±10 s) recognizers, and the detector
  reports the cumulative fraction `(dragStartY - currentY) / surfaceHeight` (positive = up), not one
  frame of movement.
- Two new MethodChannels in `MainActivity.kt`, no permissions needed: `…/screen_brightness` →
  `WindowManager.LayoutParams.screenBrightness` (clamped 0.01-1.0; `-1` hands brightness back to the
  system when the player goes away) and `…/media_volume` → `AudioManager.STREAM_MUSIC` — the level
  the volume keys control and the level actually heard. The app's own player volume stays at full so
  the HUD matches what is audible. Both services swallow every failure (a desktop host or a widget
  test has no plugin): a gesture must never break playback.
- A volume drag re-reads the system volume at drag start, so it continues from where the phone's
  volume keys left it instead of from a stale mirror.
- The gesture HUD renders **outside `PlayerControlsOverlay`** — that overlay fades to opacity 0 when
  the controls auto-hide, which used to hide the readout of a swipe that had already changed the
  value. `PlayerHudToast` wraps itself in `IgnorePointer`, and the loading/buffering indicator now
  does too (it used to swallow swipes while the stream probed). The rotate button is gone.

**Progress persistence (leaving the player wrote 0):** the app read the resume point but never wrote
it, and the back path flushed *after* `stop()` had already reset the position. New
`PlaybackProgressReporter` (`lib/features/player/application/`) mirrors the web player's cadence —
autosave on a 10 s playback delta, on pause, on seek (2 s debounce so scrubbing writes once), on end,
and on leaving the player; positions under 1 s are never persisted, and `onEnded()` marks *watched*
(0) only when the position really is at the end (media_kit reports `completed` for torn-down streams
too). `dispose()` deliberately does not flush — a save started during teardown leaves Dio's
scheduling timer pending ("A Timer is still pending…" in widget tests); the exit save belongs to
`_handleBack`, before the controller is stopped.

**Reactive `serverBaseUrlProvider`:** repositories call `updateBaseUrl()` only after reading the
saved server, and the first frame renders before that — sampling `dio.options.baseUrl` once pinned
artwork to the loopback default (the phone itself), so every poster fell back to a letter avatar
while API calls kept working. The provider now listens to the client's `baseUrlNotifier` and
invalidates itself on change.

**Continue Watching rail refresh:** the rail and grid resume from their own `MovieItem`, so after
playback the library list is reloaded (`loadLibrary(isRefresh: true)`) on return from the player —
otherwise the next tap replays the position the list was loaded with.

**Also:** `kotlin.incremental=false` in `flutter_client/android/gradle.properties` — Kotlin's
memory-mapped incremental caches fail on the USB volume (`Could not close incremental caches …`),
and neither clearing the cache nor `flutter clean` helps.

**Verification:** new `test/features/player/player_gesture_controls_test.dart` (7 cases: left/right
half, cumulative fraction, negative on swipe down, a drag never fires tap/double-tap, tap and
double-tap still work with drags enabled, inert without a callback), plus
`playback_progress_reporter_test.dart`, `playback_progress_persistence_test.dart`,
`player_screen_test.dart`, `server_base_url_provider_test.dart`, `library_screen_test.dart` and
`movie_details_screen_test.dart`; `flutter analyze lib test` 0 issues. On the Vivo I2217 a
right-half swipe moves the system media volume (`dumpsys audio` → `VOLUME GROUP AUDIO_STREAM_MUSIC`),
and leaving the player persists the position the web player then resumes from.

### 2026-09-28 — Watch progress is per device (resume no longer bleeds across devices)

**Symptom:** seeking in the laptop's web player moved the phone app's resume point — whichever
device played last set the position for every device.

**Cause:** reads were global. `/api/progress` POST already wrote the shared `progress` row *and*
`device_watch_history` (per-device rows were correct all along), but `GET /api/progress` and
`media_service.movie()` — hence `/api/movies`, the details page and the player page — read only the
shared row, so every client saw the last writer's position.

**Fix (server-side only; both clients already identify themselves):**
- `device_service.current_device_id()` — the request's device id, `None` outside a request.
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

### 2026-09-27 — Flutter device presence + authoritative playback mode

**Device presence (the phone now registers itself):**
- `DeviceIdentityService` produced a stable `dev_…` id and `DeviceAuthInterceptor` sent it as
  `X-Device-Id`, but `ApiEndpoints.deviceHeartbeat` had **no caller** — so the client never appeared in
  the Connected Devices dashboard (playback alone registers nothing; only `/api/devices/heartbeat`
  creates a row).
- Added `features/devices/data/repositories/device_repository.dart` (`sendHeartbeat`, failures
  swallowed — presence is telemetry and must never disturb playback),
  `presentation/controllers/device_presence_controller.dart` (registration ping on start, then one
  every **45 s** — the web client's cadence — paused while backgrounded, immediate ping on resume, no
  overlapping requests, timer cancelled on dispose) and `presentation/widgets/device_presence_scope.dart`
  (mounted once in `main.dart`, forwards `didChangeAppLifecycleState`; widget tests that build
  `MediaServerApp` directly never open a heartbeat timer).
- The server upserts on `X-Device-Id` (`record_device_heartbeat`), so repeated pings refresh one row
  instead of creating duplicates.
- The client User-Agent now carries `Android <ver>; Mobile` on Android: `parse_user_agent` reports a
  phone only when it sees a `Mobile` token, so the client was being filed as "Android Tablet".

**Authoritative playback mode (the badge was guessing):**
- The badge was `subtitle?.toLowerCase().contains('direct')`, but `subtitle` is the details screen's
  display string (`'2026 • 1h 43m'`) — it can never contain "direct", so every stream showed
  "HLS STREAM". Label *and* stream URL now come from the server's `direct_play` flag in
  `/api/media-info` via `features/player/domain/playback_mode.dart`; an unresolved mode renders a
  neutral `STREAM` badge rather than a claim.
- Containers the server does not serve directly (MKV/HEVC) now play through the designed HLS path
  (`/hls/<file>/playlist.m3u8`); direct-playable MP4/M4V/WebM keeps RFC 7233 byte-range `/media/<file>`.
- **Cold-start origin fix (found only on the device):** the player built its API/HLS origin from the
  *media* URL, which is the route's `http://127.0.0.1:8000` default when the player is opened without
  an explicit `server` — so on a cold start the mode probe (and the subtitle/preview calls and the HLS
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

### 2026-09-27 — Flutter release hardening, test isolation, and end-to-end device verification

**Release integrity (the APK is the source of truth):**
- `scripts/publish_update.py` now reads `packageId`/`versionCode`/`versionName`/`minSdk`/`targetSdk`
  back out of the built APK with `aapt2 dump badging` and **refuses to publish** if they disagree
  with the manifest it is about to write (`ApkIdentityError`, fail-closed). `--min-supported-code`
  publishes the enforced floor. Build-tools 36 prints `minSdkVersion:` (legacy `sdkVersion:`), both
  spellings are parsed — a real APK round-trip test caught that.
- New `scripts/release_android.py` makes build and publish one step: allocate versionCode → build
  with `--build-name/--build-number` → re-read the APK identity → publish. `pubspec.yaml` is pinned
  to the `1.0.3+103` floor so a bare `flutter build apk` cannot outrun the registry.
- Published through that path: **developer `1.0.4-dev.104`** and **developer `1.0.5-dev.105`**
  (`updates/version_registry.json` → `lastVersionCode: 105`).

**Signing:**
- The hardcoded keystore password was removed from `build.gradle.kts`. Credentials now come from
  git-ignored `flutter_client/android/key.properties` → env vars → **fail closed** (no silent
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
- Proof, not assertion: the full suite ran with the production DB snapshotted before/after —
  `movies` / `devices` / `device_watch_history` / `progress` / `settings` were **byte-identical**.
- Results: Python **250 passed, 1 skipped** (72.7 s); Flutter **128 passed, 10 skipped**, analyzer
  clean.

**Update-floor enforcement:**
- `minSupportedVersionCode` is now enforced client-side (install below the floor ⇒ mandatory update,
  the prompt cannot be dismissed) and `minAndroidSdk` is taken from the APK (24), not the stale 26.

**Fixture cleanup (via the application's own purge route):**
- `POST /api/media/delete/...` removed the two leaked test fixtures — a 23-byte
  `C:\Flicks\Mayday (2026).mkv` stub and the file-less `Moana.2016.mp4` DB row. Library went
  **14 → 12 rows**; no collateral (the real `Mayday 2026 … BONE.mkv` kept its 1656-segment cache,
  every other cached title intact). The transcoder had been re-probing that stub every ~30 s
  (5542 log lines); **zero retries after the purge**.

**Service + device verification:**
- `MediaServer` restarted (new PID) so the live process serves `/api/app/*`: `/api/app/update?channel=developer`
  returns the 104→105 manifest (sha256 matches the APK byte-for-byte), `?channel=production` 404s
  (channel isolation), `/api/app/download` returns 206 + `application/vnd.android.package-archive`.
- On the physical device (vivo I2217, Android 16): 104 installed over 103 → 4.6 shell verified live
  (`Home — Tab 1 of 3` / `Library — Tab 2 of 3` / `Settings — Tab 3 of 3`, Continue Watching ×6,
  Recently Added); the app's **own** update path found 105, downloaded, verified the hash and
  installed it → the app reports `Version 1.0.5-dev.105 / Build 105` and then
  `Your application is up to date`; the device id (`dev_e15e113a80629ba6`) survived the update.
- Playback on the device: direct-play MP4 streamed over `/media/…` byte ranges (position advanced
  5:31 → 5:54 in 20 s), and the HEVC MKV played via **HLS from its existing cache** (playlist
  `atime` = 14:37:42, cache untouched, no re-render).

**Newly observed (not fixed — outside this pass's scope):**
- The Flutter client defines `ApiEndpoints.deviceHeartbeat` but **never calls it**, and only
  `POST /api/devices/heartbeat` creates a device row — so the phone never appears in the Connected
  Devices dashboard.
- `player_screen.dart:1125` derives its DIRECT PLAY / HLS STREAM label from a *subtitle string*
  heuristic (`contains('direct') ?? true`) instead of the server's `direct_play` flag: the direct-played
  MP4 was labelled `HLS STREAM`.

### 2026-09-27 — Phase 4.6 Complete: Persistent Mobile Navigation Shell (Home, Library, Settings)

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

### 2026-09-26 — Phase 4 Complete: Library Browsing, Movie Details, & Multi-Channel Update Architecture

- **Phase 4 Library & Movie Details (Milestones 4.1–4.4):**
  - Added `GET /api/movies` and `GET /api/movie/<filename>` Flask API endpoints for Flutter client consumption.
  - Built complete Flutter library feature: `LibraryScreen` with responsive poster grid, `MovieDetailsScreen` with TMDb metadata/cast/specs, `ContinueWatchingRail`, search/sort/filter bottom sheet.
  - All search/sort/filter is client-side (300ms debounced search, A→Z/Year/Rating sort, genre multi-select).
  - Direct playback handshake: Movie Details → Player → Back navigation chain verified on physical device.
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
  - Full flow verified on Vivo I2217 (Android 16): Library → Details → Player → Back → Settings → Channel Selection.
  - APK built, signed, installed, and update subsystem tested.

### 2026-09-25 — Player Controls Transparency, Equidistant Timeline Layout, & Direct Intent Routing

- **Controls Transparency & Timeline Layout:**
  - Removed opaque solid slate container gradient (`Color(0xEE0D111A)`); replaced with subtle translucent gradient (`Colors.black.withValues(alpha: 0.50)` fading to `Colors.transparent`) so video frames and subtitles behind controls remain fully visible.
  - Symmetrical equidistant vertical spacing: balanced ~6dp clearance above and below the seekbar track.
  - Dual-time anchors: Elapsed time on the left (`0:00`), total runtime / remaining time on the right (`1:18:37`, tap-to-toggle `-remaining`) via `MainAxisAlignment.spaceBetween`.
  - Reordered controls row: Replay `↺` button first, followed by Play/Pause `⏸`/`▶`, Mute `🔊`, Speed `1×`, Audio, and Subtitles.
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

### 2026-09-24 — Phase 3C: Audio & Subtitle Track Selectors, Playback Speed, & Controls Polish

- **Android-First Modal Sheets:**
  - Added `PlaybackSpeedSheet` for variable rate playback (0.5×–2.0×) with \(\ge 52\)dp touch targets.
  - Added `AudioTrackSheet` for live multi-audio track switching with channels, codec, and language tags.
  - Added `SubtitleTrackSheet` supporting subtitle disable, demuxed embedded streams, and sidecar WebVTT files via `GET /api/subtitles/<path:filename>` (`EXT` badge indicator).
- **Controls & HUD Polish:**
  - Integrated `PlayerHudToast` transient HUD pill for instant state feedback (speed, volume, mute, seek, subtitles).
  - Replay `↺` button for instant restart to `0:00`.
  - Responsive mobile clamping: volume slider automatically hidden on compact widths (< 620dp) where hardware buttons govern volume.
  - System back navigation handled via `PopScope`, exiting native fullscreen, aborting cancel tokens, stopping playback, and preventing timer leaks.
- **Verification:**
  - Automated tests: **58 / 58 tests passed** across `flutter test`.
  - Static analysis: **0 issues found** via `flutter analyze lib test`.

### 2026-09-24 — Waitress process-inspection optimization (~240x speedup) & Android native media_kit setup

- **Root Cause of Unbrowsable / Timeout Behavior:**
  On Windows, `find_ffmpeg_info_for_path()` called `psutil.process_iter(['pid', 'name', 'cmdline'])` eagerly querying `cmdline` across every running system process (~2.1s per invocation). In `get_active_transcodes()`, this ran sequentially for every video file needing transcoding (~10 files), locking Waitress worker threads for 21–25 seconds per full HTML render (`/`, `/movie/<filename>`, `/watch/<filename>`).
  With 8 Waitress worker threads, concurrent browser requests caused task queue depth warnings (`Task queue depth is 33`) and triggered `"The operation has timed out"` on any client/health probe with standard 4–6s timeouts.
- **Resolution:**
  1. Implemented `get_active_ffmpeg_processes()` in `app/services/transcode_service.py` filtering by process name (`'ffmpeg' in name`) *before* accessing command-line memory (`proc.cmdline()`).
  2. Batched inspection in `get_active_transcodes()` to query active FFmpeg processes once per cycle rather than once per video file, immediately skipping remaining files if no FFmpeg process is running.
  3. Increased `WAITRESS_THREADS=16` in `.env` for expanded concurrent range streaming headroom.
  4. Benchmark: `get_active_transcodes()` reduced from 21.0s to **0.088s** (~240× speedup).
  5. Test suite verification: **226 / 226 tests passed** (0 failures).
- **Android Physical Device Runtime Setup:**
  Integrated `media_kit_libs_android_video: ^1.3.8` to provide native `libmpv.so` (arm64-v8a) on Android 16 / SDK 36 for the Vivo I2217 physical test device. Verified clean `MediaKit.ensureInitialized()` runtime lifecycle.


### 2026-09-22 — root cause found: segment-index collision between chunks (content loss)

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
- ~25.7 GB of `cache/hls` (9 directories, incl. the `Punjab.95.Satluj` cache) vanished around 15:45–15:46 while the service was running. **No media file was affected** (all 9 MKVs in `D:\Flicks` intact); the server rebuilt the caches automatically.
- Root-cause class identified in code: orphan detection was **fail-open**. `audit_orphaned_caches()` wrapped `video_paths()` in `try/except` and set `active_videos = []` on any exception, and skipped individual files whose cache key raised — so a transient error (e.g. `database is locked`; SQLite here has no WAL and no `busy_timeout` under 8 Waitress threads) marked *every* directory orphaned. Two automatic non-dry-run purges consume that result: `cleanup_cache_on_startup()` (every service start) and `cache-maintenance-worker` (every 2 hours). The log holds 92 historical `Purged orphaned cache directory` events including multi-GB ones (`3536856922`, `3041758276`, `2811899673` bytes), i.e. this failure mode is recurring, not new.
- Evidence limits: the app log had **no timestamps** (see below), so individual purge events could not be dated; no single purge of ~25 GB was logged, so the exact trigger of this instance remains unproven. The service was not restarted manually around the event.

### Safety fixes applied
- `audit_orphaned_caches()` now **fails closed**: enumeration exceptions, per-file cache-key failures, and "no videos found while cache directories exist" all set `degraded` + `degraded_reasons`, and the orphan lists are returned **empty** rather than complete.
- `purge_orphaned_caches()` **refuses to delete** when the audit is degraded (`refused: True`, `reason`), and skips directories holding `hls.progress`/`playlist.m3u8` written within `RECENT_CACHE_GRACE_SECONDS` (600 s) — previously a purge could delete a directory an FFmpeg worker was still writing, producing `failed to rename ... Operation not permitted` storms.
- `cleanup_cache_on_startup()` no longer purges orphans; it only clears `.part` files and enforces the transcode-cache cap. Opt in with `MEDIA_SERVER_PURGE_ON_STARTUP=1`.
- `run_production.py` configures logging with `force=True` and `%(asctime)s` — `create_app()`'s earlier `basicConfig` had won, so service logs carried no timestamps and incident timelines were unreconstructable.

### Resolved: the disappearances were caused by the test suite, not by the app or the OS
- **Root cause proven.** `cache/hls` was being deleted by `pytest` runs on this host. Cache isolation was done by rebinding Python attributes at import, and two other modules silently undo that:
  - `tests/test_app.py::MediaServerTests.tearDownClass` restores the environment and then calls `importlib.reload(app.config)`, so `app.config.CACHE_DIR` becomes the live `E:\MediaServer\cache` again;
  - `tests/test_selenium_multi_seek_coyote.py` then executes `app_module.CACHE_DIR = app_module.config.CACHE_DIR`, rebinding the app back to the live cache and defeating `tests/test_storage_retention.py`'s import-time patch.
  From that point the non-dry-run purge tests in `test_storage_retention.py` walked the **live** cache, treated every directory as orphaned (the "active" set is derived from a temporary `MEDIA_ROOT`), and deleted real transcodes.
- **Reproduced deterministically**, not inferred: a 1-second cache watchdog caught the suite deleting four real directories at 18:43:48 (`372fdd0e`, `512dd05c`, `71f81790`, `9bf62fc5` gone; `f3ec5869` shrunk 1826 → 262 MB) while test-created directories (`ActiveDualGpuPur…`, `orphan_hls_fakehash…`, `orphan_enum_error`) appeared **inside the live cache**. The service log has no purge line in that window, so the deletions were not the service's.
- This also accounts for the **17:27:52** loss of the 3.3 GB `c4d01521…` (Moana) directory: it coincided with a full-suite run, and no application purge was logged at that time.
- The **15:45** loss of ~25.7 GB is the *service-side* mechanism: `audit_orphaned_caches()` was fail-open, so a transient enumeration failure marked every directory orphaned and the automatic non-dry-run purges removed them (92 `Purged orphaned cache directory` events are in the log, including multi-GB ones). The suite shares the production database after `test_app`'s teardown reloads `app.config`, so DB contention from a concurrent test run is a plausible trigger — that part remains inference, but the fail-open path itself is proven and fixed.
- Corrections to earlier notes in this section: the deletions were **not** attributable to Storage Sense, `SilentCleanup`, Defender or the recycle bin (no events, no records, and the USN journals on `C:` cover only ~15 minutes so they cannot reach the incident). `RefreshCache` is a `\Flighting\OneSettings\` telemetry task, unrelated to disk cleanup. Kernel object-access auditing and 1-second cache watching were installed during the investigation and are what produced the proof.
- The `MEDIA_SERVER_PURGE_ON_STARTUP` recommendation is unaffected: relocating `cache/` to `D:` remains a reasonable hardening step, but it is no longer needed to explain or stop these losses.

### Test-suite isolation fix (2026-09-21)
- New `tests/conftest.py` gives the suite two independent protections:
  1. `pytest_runtest_setup` re-points `config.CACHE_DIR`, `POSTER_CACHE`, `BACKDROP_CACHE`, `SUBTITLE_CACHE`, `SUBTITLE_EMBEDDED_CACHE` and `SUBTITLE_ONLINE_CACHE` at a throwaway tree **before every test**, so no import-order accident or module reload can leave the live cache active, and it fails the test if the live cache is ever resolved;
  2. the removal primitives (`shutil.rmtree`, `os.remove`/`os.unlink`, `Path.unlink`, `Path.rmdir`) refuse any deletion inside the checkout's `cache/` tree with a loud `TEST ISOLATION VIOLATION` error.
- The rest of the environment (media root, database, archive) is intentionally left at the host's real configuration: the page-rendering tests assert against the template/CSS constants that `app/__init__.py` reads from `BASE_DIR`, and the library tests need the real media root.
- Verified: full suite **184 passed** with `cache/hls` byte-identical before and after (5 directories / 11 GB), zero watchdog events and zero violations; the guard's teeth were confirmed by a temporary probe that attempted to delete a planted file and directory inside the live cache and was refused both times.

 ### Second leak fixed: the suite also wrote into the live library and database
 - The upload fixtures in `tests/test_app.py` (`Upload_Test_Movie.2025.mp4` 22 bytes, `Mayday (2026).mkv` 23 bytes) were written into the real `C:\Flicks` library, because `app/config.py::_resolve_upload_dirs()` returns `MEDIA_ROOT` while pytest is running and no upload target is configured. Fixture rows also went straight into the production database — `Mock.mkv` (tmdb 999999) is inserted by `tests/test_app.py`, plus `RichMovie.2026.mp4` and `Moana.2016.mp4`.
 - `tests/conftest.py` now redirects the database, upload target/staging, archive and deleted directories onto the throwaway tree **through the environment before the app is imported**, so an `importlib.reload(app.config)` recomputes throwaway paths instead of live ones; `pytest_runtest_setup` re-asserts every cache, database and upload path before each test and fails the test if the live cache or the live database is ever resolved.
 - Verified after the change: library **35 files**, production database **18 rows** and live cache **11 dirs / 17,957 segments** all hash-identical before and after a full **186-test** run. The artefacts were then removed through the application's own `purge_media()` (files, stub HLS/transcode caches, subtitle cache, metadata and database rows), leaving **13** real movie rows.

 ### Playback duration honesty: report the video stream's end for HLS
 - `/api/media-info` used the container duration, so a mux whose audio/subtitles outlive the picture advertised a seek-bar tail that can never play — the same "83 % complete" wall as the transcode denominator bug, but on the player side. It now returns `_source_progress_duration(path)` (video stream's end) for HLS playback and keeps the container duration for direct play, where the browser's own timeline comes from the file.
 - Motivating case: `Punjab.95.Satluj.2026.1080p.WEBRip.DD+5.1.Atmos.x264-KIN.mkv` — the **video track ends at 8254.6 s** while audio (9839.04 s), both subtitle streams (9839.07 s) and the container (9839.07 s) run to 2:43:59, and TMDb gives the runtime as 164 min. The container matches the intended length, so the **video track itself is truncated**; the HLS cache is complete and faithful (2064 segments covering all 8254.6 s of picture), and playback correctly stops where the picture ends.


### Security finding (fixed): unauthenticated arbitrary file deletion via /api/media/delete
- `purge_media()` caught `safe_path()`'s `abort(404)` and fell back to `config.MEDIA_ROOT / filename`, then unlinked that path with no containment check. Because the Waitress service runs as **LocalSystem**, a traversal name let `POST /api/media/delete/<name>` delete **any file on the host**.
- Verified live before the fix: `..%5C..%5C..%5CMediaServer%5C<file>` returned `{"file_deleted": true}` for a file outside the library, the absolute-path variant deleted the same way, and the `..%5C..%5C..%5CWindows%5CSystem32%5Cdrivers%5Cetc%5Chosts` variant **removed the Windows hosts file** (restored from `hosts.rollback`; the exact pre-deletion content is not recoverable). There is still no authentication in front of this route.
- Fix: the fallback is accepted only when `_is_within_media_roots(candidate)` is true, otherwise the call returns `{'success': False, 'error': 'Unsafe or unknown media path'}`; the unlink itself is additionally gated on containment. Regression tests: `tests/test_media_delete_safety.py` (fail without the fix).

### Transcode completeness fix (container vs video duration)
- `source_video_duration()` measures the **video stream's end** (`ffprobe -read_intervals <midpoint>%+99999`, ~0.3 s, memoised per path/size/mtime) instead of trusting `format.duration`.
- `DualGPUTranscodeJob` plans chunks and validates coverage against that value. `cleanup_cache_on_startup`/`transcode_status` report it too.
- `_finalize()` writes `#EXT-X-ENDLIST` **only when coverage validates** (≥ `MIN_COVERAGE_RATIO`, 0.98 of video duration); a failed validation leaves an EVENT playlist plus `progress=error`, bounded by `MAX_VALIDATION_ATTEMPTS` (3) so the auto-transcoder cannot re-encode the same tail forever.
- Per-chunk underproduction detection: a chunk that exits 0 while rendering < `MIN_CHUNK_YIELD_RATIO` (0.5) of its expected duration retires that GPU for the job and the chunk is retried on a healthy worker.
- Motivating case: a WEBRip whose audio/subtitles run ~26 min past the last video frame (video ends 8254.6 s inside a 9839.1 s container) was scored 83.9 % complete forever — every tail chunk could only emit a zero-duration segment.

---

## 1. Executive summary

This is a Flask-based personal media server designed for LAN playback and remote access. The codebase has been substantially modularized from the earlier monolithic application into an `app/` package containing routes, services, utilities, configuration, and database code. The server supports direct media streaming, on-demand HLS transcoding, dynamic multi-GPU chunked transcoding, TMDb metadata, local subtitles, resumable uploads, library management, device telemetry, live playback telemetry, live video seek preview thumbnails, storage retention policies, automated orphaned cache governance, and Cloudflare Tunnel remote access.

The system is deployed on Windows 11 as persistent background Windows Services (`MediaServer` via NSSM and `Cloudflared`), surviving reboots without user login and supporting automatic crash recovery. Hardware transcoding is fully operational using dual AMD GPUs (Radeon RX 560X discrete + Radeon Vega 8 integrated).

---

## 2. Current repository architecture

### Application entry points

- `app.py` — lightweight executable entry point.
- `app/__init__.py` — application factory, route registration, and compatibility exports.
- `app/config.py` — environment-driven paths, limits, and runtime settings.
- `app/db.py` — SQLite connection, schema, and migration support.
- `run_production.py` — production WSGI entry point (Waitress on Windows, Gunicorn on Linux).

### HTTP routes

- `app/routes/pages.py` — HTML pages and page navigation (`/`, `/library`, `/details/<file>`, `/watch/<file>`, `/devices`, `/manage`).
- `app/routes/api.py` — JSON/API endpoints including devices, metadata, seek preview thumbnails, transcode progress, and playback state.
- `app/routes/media.py` — media streaming, RFC 7233 byte-range delivery, and HLS segment serving.
- `app/routes/subtitles.py` — local subtitle/WebVTT delivery and format conversion.
- `app/routes/upload.py` — resumable/chunked upload workflow with smoothed ETA.

### Services

- `chunk_transcode_service.py` — dynamic multi-GPU chunked transcoding engine dividing source media across multiple GPU workers.
- `gpu_service.py` — hardware GPU capability detection, adapter binding, and engine utilization telemetry.
- `transcode_service.py` — FFmpeg/HLS transcoding, hardware acceleration (AMF/VAAPI), caching, resume, and cleanup.
- `preview_service.py` — video seek hover preview thumbnail extraction and caching.
- `media_service.py` — media probing, paths, and media operations.
- `media_resolver.py` — automatic/forensic media identification and TMDb matching.
- `scanner_service.py` — library discovery and ingestion.
- `tmdb_service.py` — TMDb API integration.
- `subtitles_service.py` — subtitle discovery/conversion/processing.
- `device_service.py` — client/device identification, telemetry, heartbeats, and device history.
- `worker_service.py` — background worker coordination.
- `system_service.py` — system-level status/telemetry functionality and multi-GPU utilization reporting.

### Utilities

- `filesystem.py` — safe filesystem/path helpers.
- `formatting.py` — display formatting helpers.
- `subtitles.py` — subtitle parsing/conversion helpers.

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
- **Hold-to-Speed Removal:** Completely removed hold-to-accelerate (2×) gesture from player pointer events and removed its entry from `#shortcutsModal` while preserving the standard speed dropdown.
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
- **Periodic (4-Hour) TMDb Metadata Refresh & Manual Scan Trigger:** Implemented automated daemon worker (`metadata-refresh-worker`) in `worker_service.py` to refresh TMDb metadata (ratings, vote averages, runtime, tagline, certifications, cast, artwork) every 4 hours, added `last_metadata_refresh` schema migration in SQLite, and synchronized manual UI "↻ Scan" trigger to refresh both filesystem additions and existing metadata.
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
- **Tiered Drive Architecture:** Tiered the media server across fast primary NVMe SSD (`C:`) and high-capacity secondary volume (`D:`):
  - **Fast NVMe SSD (`C:`):** Hosts the OS, Waitress WSGI server, SQLite database (`media.db`), in-progress transcode scratch, seek-preview thumbnails (`cache/previews`), and completed multi-GPU HLS stream segments (`cache/hls`) for zero-stutter RFC 7233 delivery.
  - **Mass Secondary Volume (`D:`):** Hosts raw media library storage (`D:\Flicks`), resumable upload staging (`D:\Flicks\.uploads`), and cold original file archives (`D:\Flicks\.archive`).
- **Multi-Root Dynamic Media Discovery:** Implemented `config.get_media_roots()` returning all active roots (`[MEDIA_ROOT, UPLOAD_TARGET_DIR, ARCHIVE_DIR]`). Updated `video_paths()`, `safe_path()`, `movie()`, and `poster_for()` to discover and serve media seamlessly regardless of which configured drive volume it resides on.
- **Cross-Volume Cache Key Continuity:** Enhanced `hls_cache_dir()` and `preview_dir()` to compute relative paths against alternative roots (`root / rel`). When media files move across volumes (e.g. `C:` to `D:`), their cache keys remain 100% deterministic and active, preventing cache invalidation, playback 404s, or false-positive orphaned directory deletion.
- **Cross-Volume Subtitle Discovery & Authorization:** Updated `tracks()` in `subtitles_service.py` to compute relative filenames against all active roots and search both `path.parent` and `config.MEDIA_ROOT` for sidecar `.srt`/`.vtt` files. Hardened `/subtitles/<path:filename>/<name>` to verify filesystem authorization across all configured media roots.
- **Host Headroom Reclaimed:** Reclaimed over **24.2 GB of SSD space** on `C:`, increasing free headroom from 14.3 GB to **38.59 GB** while all 4 library titles (*Coyote vs. Acme*, *Moana*, *Star Wars*, *The Odyssey*) remain fully playable with complete subtitle coverage.
- **Multi-Chunk HLS Discontinuity Alignment & Monotonic Timestamp Preservation:** Eliminated playback resets to `0:00` during forward seeking across chunk boundaries on transcoded media (*Coyote vs. Acme*). Removed `-avoid_negative_ts make_zero` in `chunk_transcode_service.py` ensuring `-output_ts_offset` preserves timeline timestamps, integrated RFC 8216 `#EXT-X-DISCONTINUITY` insertion between chunk boundaries in `_update_master_playlist()`, and added automatic on-the-fly disk playlist reconciliation (`reconcile_hls_playlist_discontinuities()`) in `app/routes/media.py`. Hardened `templates/player.html` error listeners to preserve seek positions on fallback. Verified via 163-test pytest suite, Selenium forward-seek test, and live Chrome DevTools MCP inspection with zero `DEMUXER_ERROR_COULD_NOT_PARSE` events.

### Unified navigation header, custom select pickers & mobile rail polish
- **Frosted Obsidian Glass Header:** Redesigned top navigation header across all 5 primary pages (`/`, `/movie/<filename>`, `/player/<filename>`, `/manage`, `/devices`) with frosted glass background (`rgba(11, 15, 23, 0.88)` with `backdrop-filter: blur(24px)`), translucent border, and ambient shadow.
- **3D Glossy Play Brand Identity:** High-fidelity vector SVG brand icon with multi-stop crimson linear gradients, radial specular highlights, and ambient drop shadows, paired with two-tone typography (**Anis'** + **Home Media Server**) and brand subtitle (**PLAY • ORGANIZE • ENJOY**).
- **Responsive Mobile Action Rail:** Replaced non-functional hamburger menus on mobile viewports (\(\le 768\text{px}\)) with touch-friendly, horizontal swipeable action rails (`overscroll-behavior-x: contain; touch-action: pan-x; -webkit-overflow-scrolling: touch;`), allowing instant single-tap access to primary actions.
- **Desktop & Mobile Search Density Polish:** Completely removed the redundant A-Z sort dropdown across both desktop and mobile views in favor of natural library browsing and direct search input filtering.
- **Home Page Section Hierarchy (Telemetry at Footer):** Repositioned the System Telemetry HUD (`#systemTelemetryCard`) to the footer of the home page (strictly after "All Movies"), prioritizing user media and continue-watching cards while keeping technical stats accessible at the bottom.
- **Universal Top-Layer Customizable `<select>` Popovers:** Adopted modern Customizable Select API (`appearance: base-select` and `select::picker(select)`) to replace sharp, bright blue Windows system menus with top-layer frosted obsidian glass popovers (`rgba(18, 22, 32, 0.96)`, `backdrop-filter: blur(24px)`), rounded corners (`12px`), brand red active highlights (`#e50914`), white checkmarks (`select option::checkmark`), and smooth rotating chevrons (`select:open::picker-icon`). Applied universally across `/manage` storage retention policy, playback speed (`#speed`), and in-player subtitle settings modal dropdowns.
- **Chromium Hls.js Precedence Invariant:** Enforced `window.Hls && Hls.isSupported()` precedence over native `canPlayType` before falling back in `templates/player.html`. Resolves broken multi-chunk discontinuity seeking on Windows Chromium browsers where `canPlayType` evaluates to `"maybe"` (truthy) but cannot demux multi-chunk timeline offsets. Verified via automated Selenium multi-seek test across 5 seek points (60s, 180s, 360s, 450s, 600s).
- **Mobile Player Controls Expansion & Dedicated Seekbar Spacing:** Restored primary player controls (`↺` Restart, `▶`/`⏸` Play, `🔊` Mute, `1×` Speed, `CC ⚙` Subtitles/Settings, Aspect Ratio, Rotate Screen, PiP, Nerd Stats) on mobile viewports within a swipeable non-overflowing rail (`overflow-x: auto`), cleanly hid desktop-only controls (`#volume` and `#shortcutsBtn`), explicitly hid redundant `-10s`/`+10s` buttons on mobile in favor of seekbar/double-tap gestures, and eliminated the dead space between `.seek-time-row` and seekbar (`margin-bottom: -9px !important`).
- **Unified "Anis' Home Media Server" Branding & In-App User Manual:** Standardized brand identity across all pages to **Anis' Home Media Server** with fluid clamp typography preventing text wrapping or horizontal clipping on compact mobile devices (320px–480px). Implemented comprehensive in-app User Manual (`/manual`) with quick category navigation pills, full shortcut cheatsheet, multi-GPU streaming explanations, and added "How to use" link across all site footers. Authored offline markdown manual (`docs/MANUAL.md`).


---

## 4. Next steps & active roadmap

### Secondary / parked
1. **Automatic OpenSubtitles behavior:** local subtitles work; incorrect automatic OpenSubtitles behavior is parked.
2. **Authentication/access control:** the stable Cloudflare hostname is not authentication. Add access control before wider public sharing.
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

# Full automated test suite (164 tests)
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

1. **Production Concurrency Tuning & Benchmarking:** Benchmark worker and thread pools against remote stream latency and Cloudflare tunnel limits.
