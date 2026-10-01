# Flutter Client — Phase Status & Handoff

> **Last updated:** 2026-10-02
> **Active branch:** `feat/flutter-production-player`
> **Package ID:** `in.anisparvez.media_server_client`
> **Source conversations:** `8478b150` (Phase 1 & 2), `995057c0` (Phase 2–3C), `fbcf1933` (Phase 4 + Multi-Channel Updates), `96ba34db` (Phase 4.7 + TV Pass 2), `3b535dcb` (TV Pass 2 Polish & PlayerScreen Segregation), `1a6914ec` (Fire TV Driver Lock & Software Fallback), `b961df1a` (UX Bugs: Phase 1 Investigation, Phase 2 Spatial Traversal, Phase 3 Player Back)
> **Purpose:** Persistent handoff document. **Read this before touching the Flutter client.**

---

## Phase Overview

| Phase | Title | Status |
|-------|-------|--------|
| 1 | Flutter Client Foundation | ✅ COMPLETE — committed (`5b0b1fa`, `eadb257`) |
| 2 | Video Player Proof-of-Concept | ✅ COMPLETE — all 6 stages verified on LAN & WAN (`f8e8c23`) |
| 3A | Production Player Core Architecture | ✅ COMPLETE — committed on `feat/flutter-production-player` |
| 3B | Android-First Timeline & Live Seek Preview | ✅ COMPLETE — committed (`2e95246`) |
| Android Native | Physical Device Engine (`libmpv.so`) | ✅ COMPLETE — Vivo I2217 (Android 16, SDK 36) |
| 3C | Audio & Subtitle Track Selectors, Speed & Controls Polish | ✅ COMPLETE — 58/58 tests, 0 analyzer issues |
| 4.1 | Library Data Layer & API Endpoints | ✅ COMPLETE — API contracts frozen |
| 4.2 | Library UI, Movie Card Grid, Continue Watching Rail | ✅ COMPLETE — physical device verified |
| 4.3 | Library Search, Sort, Filter | ✅ COMPLETE — debounced search, 3 sort modes, genre filter |
| 4.4 | Movie Details Screen & Playback Handshake | ✅ COMPLETE — details → play → back flow verified |
| 4.5 | Multi-Channel Distribution & In-App Update Architecture | ✅ COMPLETE — update subsystem operational |
| 4.6 | Persistent Bottom Navigation & Settings Integration | ✅ COMPLETE — 3-tab shell (Home, Library, Settings), 143 passed / 10 skipped |
| 4.7 | Fire TV & Android TV 10-Foot Experience (Universal APK) | ✅ COMPLETE — Single universal APK (`in.anisparvez.media_server_client`) for Mobile & TV, collapsible obsidian rail (`TvSideNavigationRail`), borderless fullscreen player, D-pad remote transport, edge traversal bridge, debounced exit dialog, Pass 2 leanback UI, 240+ tests |

---

## Current State (2026-10-02, after UX Bug Fixes: Phase 2 Spatial Focus, Phase 3 Player Back & Phase 4 Overlay State)

**Git status:** `feat/flutter-production-player` — working branch with Pass 2 TV leanback refinements, `PlayerScreen` modularization, 2D weighted spatial focus traversal, 2-step player Back navigation, and coordinated playback overlay state management.
**Test Results (verified 2026-10-02):**
- Flutter unit & widget tests: **261 passed, 12 skipped** (0 failures).
- Flutter static analysis (`flutter analyze`): **0 issues found**.

### Coordinated Playback Overlay State Management (Phase 4 Complete)

- **Issue:** Independent overlay states rendered simultaneously (e.g. "Buffering Stream" loading card + "+10 sec" seek HUD pill + Center Play/Pause button stacked together in the viewport center), transient HUD toasts lingered after stream states changed, and rapid D-pad seeking caused jarring buffer flashes.
- **Root Causes:**
  1. `isOpening || _isBuffering`, `_isHudVisible`, and Center Play/Pause (`!widget.isBuffering && !widget.isDoubleTapSeeking`) evaluated disconnected boolean flags, creating competing center overlays.
  2. Relative seeking (`_seekRelative`) called `_showHudToast` and `_controller.seek()`, triggering immediate backend buffering that displayed both `PlayerLoadingIndicator` and `PlayerHudToast` simultaneously.
  3. `_hudTimer` fired asynchronously without awareness of seek settle or buffering transitions.
  4. Rapid seeks did not accumulate delta (+10s -> +20s -> +30s), repeatedly restarting uncoordinated timers.
- **Implemented Fix (Coordinated State Model):**
  - **`PlaybackOverlayStatus` & `PlaybackOverlayType` Enum:** Added clean domain model (`lib/features/player/domain/player_overlay_status.dart`) enforcing mutual exclusivity across `none`, `opening`, `buffering`, `seeking`, and `toast`.
  - **Single Coordinated Overlay Slot:** Unified center canvas rendering in `PlayerScreen`:
    - Priority 1: User-initiated transient actions (`seeking` with accumulated delta `+10s` -> `+20s`, `toast` for volume/speed/aspect/track).
    - Priority 2: Cold start loading (`opening`).
    - Priority 3: Stream underrun (`buffering`), automatically suppressed during active relative seek settle windows (1000ms) and timeline scrubbing gestures.
    - Priority 4: Normal playback (`none`).
  - **Center Play/Pause Suppression:** Passed `isOverlayActive: overlayStatus.isVisible` to `PlayerControlsOverlay`, suppressing center play/pause whenever any transient overlay is active.
  - **Immediate Buffering Dismissal:** Clears buffering indicator instantaneously upon `bufferingStream` emitting `false`.
  - **Comprehensive Verification:** 13 new dedicated widget and domain tests in `test/features/player/player_overlay_state_test.dart`. All 102 player tests and 261 total tests pass.

### TV Remote Player Back Key Behaviour (Phase 3 Complete)

- **Issue:** During media playback on TV/Fire TV, pressing Back would immediately terminate playback and exit the player route if controls were hidden, while requiring multiple Back presses to unwind focus when controls were visible.
- **Root Causes:**
  1. `PopScope` passed `forceExit: isTv`, which forced immediate exit on TV and bypassed controls visibility checks.
  2. In `player_key_dispatcher.dart`, when `!controlsVisible`, pressing Back (`LogicalKeyboardKey.escape` / `LogicalKeyboardKey.goBack`) invoked `onHandleBack(forceExit: true)`.
  3. When controls were visible, Back unwound focus from Zone 2 to Zone 1 and hid controls (`onHideControls()`) rather than performing normal player exit.
- **Implemented Fix (2-Step TV Remote Model):**
  - **First Back Press (Controls Hidden):** Back calls `onUserInteraction()` and `onSetTvFocusZone(TvPlayerFocusZone.timeline)`, revealing controls, resetting the auto-hide timer, restoring timeline scrubber focus, and consuming the event without stopping playback or exiting.
  - **Second Back Press (Controls Visible):** Back invokes `onHandleBack(forceExit: false)` and performs normal player exit: cancels timers, flushes/disposes watch progress, stops the media controller, and pops the route cleanly.
  - `PopScope` calls `_handleBack()` without `forceExit: isTv`. All 14 remote tests and 248 total tests pass.

### 2D Weighted Spatial Focus Traversal Policy (Phase 2 Complete)

- **Issue:** Flutter's default `DirectionalFocusTraversalPolicyMixin` clips focus candidate search to strict 1D geometric bands. When navigating D-pad Up/Down, focus skipped adjacent elements that did not horizontally overlap (e.g. preset chips in connection settings, staggered cards in grids).
- **Implemented Fix:**
  - Implemented `TvSpatialFocusTraversalPolicy` (`lib/core/navigation/tv_spatial_focus_traversal_policy.dart`), calculating directional candidate scores via weighted 2D vector distance:
    $$\text{score} = \Delta\text{primary} \times 4.0 + \Delta\text{orthogonal} \times 1.0 + \Delta\text{align} \times 0.25$$
  - Enforced a 60% visual row/column overlap gate (`overlapRatio > 0.6`).
  - Attached app-wide to `MediaServerApp` root builder in `app.dart` and `tvContentFocusScopeProvider` in `app_shell.dart`. Upgraded connection preset chips to `TvFocusable`.

### Hardware Playback Hardening: Fire TV Stick 4K Driver Lock Prevention & Software Fallback

During 10-foot playback on the Amazon Fire TV Stick 4K (`AFTMM`, MediaTek MT8695/MT8696 + PowerVR GE9215 GPU), certain titles (such as *Scary Movie* at 1916×800) previously locked the video pipeline: audio would play while video frames froze or remained completely black.
- **Root Cause:** Zero-copy `hwdec: mediacodec` passes decoded hardware buffers directly to Android `SurfaceTexture` / `ANativeWindow` as EGLImages. When video dimensions are not 16-byte-aligned (e.g. 1916px width), PowerVR rejects the EGLImage (`E IMGSRV : IsTextureConsistent: IMGEGLImage is not consistent`), leaving display fences unsignaled. The MediaTek kernel driver then deadlocks indefinitely (`E MDP : wait input fence[353] timeout`), causing 100% frame drops across the device.
- **Solution — `mediacodec-copy`:** In `MediaKitPlayerAdapter`, Android configuration now specifies `hwdec: 'mediacodec-copy'`. Frames are copied and rendered via standard OpenGL ES texture shaders (`vo=gpu`), eliminating direct ANativeWindow fence sharing with the display processor.
- **Dynamic Software Fallback:** If hardware decoding encounters any failure or if the first frame fails to render within 4 seconds (`_firstFrameRendered` tracking via `videoController.waitUntilFirstFrameRendered`), the adapter dynamically invokes `fallbackToSoftwareDecoder()`, setting `hwdec: 'no'` (libavcodec CPU decoding) and issuing a micro-seek to cleanly flush decoder buffers without interrupting audio.
- **Verification:** Verified with hardware playback on physical Fire TV Stick 4K (`192.168.1.70:5555`): *Batman: Knightfall* (1920×1080) and *Scary Movie* (1916×800) render full-screen video with zero dropped frames.

### PlayerScreen Modularization & Architecture Segregation (2,283 → 1,232 lines)

`PlayerScreen` previously grew beyond 2,280 lines into a monolithic class managing playback lifecycle, gesture detectors, 10-foot TV D-pad navigation, Chromecast / DLNA remote polling, metadata fetching, and mobile portrait layout.

The screen has been segregated into 5 modular, focused components:
- **`domain/tv_player_focus.dart`:** Defines `TvPlayerFocusZone` enum (`none`, `timeline`, `controls`) for 10-foot remote focus management. Exported directly from `player_screen.dart` for backward compatibility.
- **`presentation/widgets/player_cast_bar.dart`:** `PlayerCastBar` widget encapsulating Chromecast / DLNA session progress and remote status.
- **`presentation/widgets/player_details_panel.dart`:** `PlayerBrandHeader` and `PlayerDetailsPanel` managing portrait mobile split-view details, synopsis, stream specifications, and server connection modal.
- **`presentation/widgets/player_key_dispatcher.dart`:** `PlayerKeyDispatcher` static helper managing universal media keys, 2-zone TV remote D-pad state machine, and desktop physical keyboard shortcuts.
- **`infrastructure/player_media_resolver.dart`:** `PlayerMediaResolver` isolating filename extraction, effective URL mapping, API server origin detection, seek-preview frame metadata probing, WebVTT sidecar discovery, and `/api/media-info` metadata probing.

Result: `player_screen.dart` reduced from 2,283 lines to 1,232 lines (-1,051 lines, ~46% reduction). All 86 player tests and 118 shell/feature tests pass with zero analyzer warnings.

### Device presence — the client now registers itself

`DeviceIdentityService` gave every install a stable `dev_…` id and `DeviceAuthInterceptor` sent it as
`X-Device-Id`, but nothing ever *called* `ApiEndpoints.deviceHeartbeat`, so the phone never appeared
in the server's Connected Devices dashboard.

- `features/devices/data/repositories/device_repository.dart` — `sendHeartbeat()` (failures swallowed:
  presence is telemetry and must never disturb playback).
- `features/devices/presentation/controllers/device_presence_controller.dart` — one registration ping
  on start, then one every **45 s** (the web client's cadence in `templates/library.html`), paused while
  the app is backgrounded, immediate ping on resume, no overlapping requests, timer cancelled on dispose.
- `features/devices/presentation/widgets/device_presence_scope.dart` — mounted once in `main.dart`
  around `MediaServerApp` and forwards `didChangeAppLifecycleState` (widget tests that build
  `MediaServerApp` directly therefore never open a heartbeat timer).
- The server upserts on `X-Device-Id` (`record_device_heartbeat`), so repeated pings refresh one row.
- The client's User-Agent now carries `Android <ver>; Mobile` on Android: the server's
  `parse_user_agent` reports a phone only when it sees `Mobile`, otherwise the client was filed as
  "Android Tablet".

### Authoritative playback mode (was a display-string guess)

The player decided its badge with `subtitle?.toLowerCase().contains('direct')`, where `subtitle` is the
display string from the details screen (`'2026 • 1h 43m'`) — it can never contain "direct", so every
stream was labelled HLS. The player already fetches `/api/media-info`, which carries the server's
`direct_play` flag, so the label and the stream URL are now both derived from it:

- `features/player/domain/playback_mode.dart` — `PlaybackMode.direct | hls | unknown` with
  `badgeLabel` / `specLabel`; `unknown` is rendered as a neutral `STREAM` badge, never as a claim.
- `PlayerScreen._bootstrap()` resolves the mode first, then opens the container the way the server says
  it must be served: direct byte-range `/media/<file>` or the HLS playlist
  `/hls/<file>/playlist.m3u8` (the designed path for MKV/HEVC, which libmpv can also play directly).
- Regression tests: `test/features/player/playback_mode_indicator_test.dart` (a subtitle containing
  "direct" can no longer override the server) and `test/support/recording_player_controller.dart`.

**Cold-start origin (found on the device, not in tests):** the player derived its API/HLS origin from
the *media* URL, which is the route's `http://127.0.0.1:8000` default whenever the player is opened
without an explicit `server` — so on a cold start the mode probe, the subtitle/preview calls and the
HLS URL all targeted the phone itself (`DioException [connection error]: Connection refused`,
captured in logcat). The badge therefore fell back to `STREAM`. `_resolveApiOrigin()` now mirrors
`_resolveEffectiveMediaUrl()`: the saved/active server wins over a loopback media origin, and every
API call and HLS URL goes through that origin (`_apiServerOrigin()`), with the shared
`apiClientProvider` client instead of a bare `Dio()`. The probe also logs its outcome
(`[Player] media-info probe: …`) so a future failure is visible in `adb logcat`.

### Live-server tests are opt-in (host safety)

Ten Flutter tests and one Python E2E drive a **running** server, and one of them registered a
device row in the production `devices` table every time the suite ran. They are now skipped unless
the operator asks for them:

```powershell
$env:MEDIA_SERVER_LIVE_TESTS = "1"      # opt in (Flutter + Python)
$env:MEDIA_SERVER_TEST_ORIGIN = "http://127.0.0.1:8000"   # optional, Flutter only
```

- Gated: `test/live_server_connection_test.dart`, `test/streaming_http_contract_test.dart`,
  `test/features/player/runtime_player_3a_test.dart` (playback tests only),
  `test/features/player/runtime_player_3b_test.dart`.
- The gate lives in `test/support/live_server_gate.dart`.
- `tests/test_selenium_multi_seek_coyote.py` no longer prefers the live port-8000 service: it
  serves its own in-process app on an ephemeral port (conftest points that app at the throwaway
  cache/database) and skips when the isolated cache cannot serve the scenario.

### Physical Device Verification

- **Device:** Vivo I2217 (vivo V2338, Android 16, API 36)
- **Verified flows:**
  - Network & Cleartext Traffic: `src/main/AndroidManifest.xml` updated with `INTERNET`, `ACCESS_NETWORK_STATE`, and `usesCleartextTraffic="true"` (resolves "Operation not permitted" SocketException in release APKs).
  - URL Normalization: `SettingsService.sanitizeUrl` normalizes schemes (`http://`) and trailing slashes for manual IP inputs (`192.168.1.16:8000`).
  - Active Origin Sync: `LibraryRepository` auto-synchronizes `dio.options.baseUrl` from `SettingsService` before every request; `ConnectionScreen` auto-persists selected origin when navigating.
  - Distinct Navigation Icons: Header Settings uses `Icons.settings_rounded` (⚙️) and search row uses `Icons.filter_list_rounded` (☰⌵), eliminating duplicate slider icons.
  - Published and installed Build 103 (`1.0.3-dev.103`) via `publish_update.py` and `adb install -r`.
  - Library → Movie Details → Resume/Play → Production Player → Back → Details → Library live on LAN.
  - Settings Sheet: server info, device ID, version info, channel selection, update status.

### Player gestures: volume & brightness swipes (2026-09-28, `a0877ce`)

Swiping up/down on the video surface drives the phone's own levels — **left half = brightness, right
half = system media volume** — with a HUD readout (`N% Brightness` / `N% Volume`). A full-height
swipe covers the whole range, and the drag fraction is applied as an offset from the value captured
at drag start, so the mapping stays absolute.

| File | Purpose |
|------|---------|
| `lib/features/player/infrastructure/screen_brightness_service.dart` | Channel `…/screen_brightness` → `WindowManager.LayoutParams.screenBrightness` (clamped 0.01-1.0; `-1` restores the system level). Failures swallowed; `supported = false` after `MissingPluginException` |
| `lib/features/player/infrastructure/media_volume_service.dart` | Channel `…/media_volume` → `AudioManager.STREAM_MUSIC`, 0-100 — the level the phone's volume keys control |
| `lib/features/player/presentation/widgets/double_tap_seek_detector.dart` | Opt-in vertical drags; reports the cumulative fraction `(dragStartY - currentY) / surfaceHeight` (positive = up); a drag never satisfies the tap/double-tap recognizers |
| `lib/features/player/presentation/widgets/player_hud_toast.dart` | HUD pill; wraps itself in `IgnorePointer` so it never blocks the surface |
| `test/features/player/player_gesture_controls_test.dart` | 7 cases — halves, cumulative reporting, gesture coexistence |

Invariants that bite:
- The gesture HUD must render **outside `PlayerControlsOverlay`** (it fades to opacity 0 on
  auto-hide, and the readout used to vanish with it). The HUD lives in the player's own stack.
- Anything overlaying the surface must not eat gestures: the loading/buffering indicator is wrapped
  in `IgnorePointer` — a full-screen layer above the surface kills swipes silently.
- The right-half swipe is the **system** volume; the app's own player volume stays at full, so the
  HUD matches what is audible.
- A volume drag re-reads the system volume at drag start (the volume keys move it independently).
- `PlaybackProgressReporter.dispose()` never flushes — a save started during teardown leaves Dio's
  timer pending in widget tests. The exit save is in `_handleBack`, before `_controller.stop()`.

Also in this pass (`a0877ce`): `PlaybackProgressReporter` (the app now *writes* watch progress —
10 s delta, pause, debounced seek, end, back path; `onEnded` marks watched only at the true end);
`serverBaseUrlProvider` is reactive (artwork was pinned to the loopback default on the first frame);
the Continue Watching rail and grid reload after playback (`loadLibrary(isRefresh: true)`);
`kotlin.incremental=false` for the USB volume.

---

## Strict Invariants (MUST preserve)

1. **Player feature is frozen except for owner-approved fixes:** `flutter_client/lib/features/player/` must not be modified without a concrete requirement. Two such requirements have been delivered (authoritative playback-mode label + HLS routing for containers the server does not serve directly); anything else needs a stated reason in `docs/PROJECT_STATUS.md` first.
2. **Single `<script>` block:** `templates/player.html` has exactly one `<script>` block (production web player).
3. **API contracts frozen:** `GET /api/movies` and `GET /api/movie/<filename>` response schemas are consumed by the Flutter client and must not change without updating both sides.
4. **Single App ID:** Android package is `in.anisparvez.media_server_client` — no separate dev/prod package IDs.
5. **Same signing key:** All builds (production and developer) use the same release keystore.
6. **Test isolation:** `tests/conftest.py` redirects cache, database, uploads, updates to throwaway temp dirs. Never bypass this.

---

## Phase 4.6 — Persistent Bottom Navigation Shell (COMPLETE)

### Navigation Architecture

```
ConnectionScreen (Server Origin & Setup Gate: '/')
       ↓ (context.go('/home'))
AppShell (Persistent Bottom Navigation: StatefulShellRoute.indexedStack)
 ├── Branch 0: HomeScreen ('/home')
 │     ├── Frosted Obsidian Brand Header + Scan Library Trigger
 │     ├── Continue Watching Rail (In-progress media with progress bars)
 │     ├── Browse Full Library Quick Banner
 │     ├── Recently Added Responsive Grid (Direct navigation to details)
 │     └── Polished Empty / Error / Loading States with Retry & Scan
 ├── Branch 1: LibraryScreen ('/library')
 │     ├── Full Movie Poster Grid
 │     ├── Instant 300ms Debounced Title/Year/Genre Search
 │     ├── Multi-criteria Sorting (A→Z, Year, Rating) & Multi-Genre Filters
 │     └── Pull-to-refresh & Server Ingestion Scan
 └── Branch 2: SettingsScreen ('/settings')
       ├── Active Server Origin Configuration ('Change' pushes '/')
       ├── CSPRNG Persistent Device Identity with 1-tap Clipboard Copy
       ├── Monotonic Production / Developer Channel Switcher with Downgrade Warnings
       └── Live Update Checks & Background Download / Install Dialog

Fullscreen Top-Level Destinations (Strictly outside shell):
 ├── MovieDetailsScreen ('/movie-details') ──→ Pushed over shell; back pops to active tab
 ├── PlayerScreen ('/player')              ──→ Strictly fullscreen; zero bottom bar; intent routable
 └── PlayerPocScreen ('/player-poc')        ──→ Phase 2 test harness
```

### Key Files — Shell & Navigation

| File | Purpose |
|------|---------|
| `lib/features/shell/presentation/screens/app_shell.dart` | `AppShell` with Material 3 obsidian `NavigationBar`, `PopScope` back stack |
| `lib/features/home/presentation/screens/home_screen.dart` | `HomeScreen` dashboard with Continue Watching, Recent Grid, empty states |
| `lib/features/settings/presentation/screens/settings_screen.dart` | Embedded Settings tab screen with frosted obsidian brand header |
| `lib/features/updater/presentation/widgets/settings_content.dart` | Reusable settings body shared by `SettingsScreen` and `SettingsSheet` |
| `lib/app/routes.dart` | `GoRouter` with `StatefulShellRoute.indexedStack` and top-level fullscreen routes |
| `test/features/shell/app_shell_test.dart` | Full shell integration tests: tabs, back behavior, player isolation |
| `test/features/home/home_screen_test.dart` | Home screen widget tests: continue watching, recent grid, scan, empty states |
| `test/features/settings/settings_screen_test.dart` | Settings screen widget tests: server, version, channels, updates |

---

## Phase 4.5 — Multi-Channel Distribution & In-App Update Architecture (COMPLETE)

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    Flutter Client (Android)                        │
│                                                                    │
│  SettingsSheet ──→ UpdateController ──→ UpdateRepository           │
│       ↕                  ↕                    ↕                    │
│  Channel Selection    Lifecycle FSM     HTTP: GET /api/app/update  │
│  (SharedPreferences)  (Riverpod)        HTTP: GET /api/app/download│
│       ↕                  ↕                                         │
│  AppChannel.fromString  ManifestValidation (fail-closed)          │
│       ↕                  ↕                                         │
│  AppInstallerBridge ──→ Native MethodChannel ──→ FileProvider     │
│                         (MainActivity.kt)        (ACTION_VIEW)    │
└──────────────────────────────────────────────────────────────────┘
                              ↕
┌──────────────────────────────────────────────────────────────────┐
│                    Flask Backend (Server)                          │
│                                                                    │
│  GET /api/app/update?channel=...  → manifest.json (no-cache)      │
│  GET /api/app/download?channel=... → APK binary (RFC 7233)        │
│  scripts/publish_update.py → Atomic publication                   │
│  updates/version_registry.json → Global monotonic versionCode     │
└──────────────────────────────────────────────────────────────────┘
```

### Key Files — Update Subsystem

| File | Purpose |
|------|---------|
| `lib/core/models/app_channel.dart` | `AppChannel` enum: `production`, `developer`, compile-time default |
| `lib/features/updater/data/models/update_manifest.dart` | `UpdateManifest` model + fail-closed `ManifestValidationResult` |
| `lib/features/updater/data/repositories/update_repository.dart` | HTTP manifest fetching, APK download with progress, SHA-256 verification |
| `lib/features/updater/infrastructure/app_installer_bridge.dart` | Abstract bridge + `NativeAppInstallerBridge` (MethodChannel to Android) |
| `lib/features/updater/presentation/controllers/update_controller.dart` | `UpdateController` Riverpod Notifier: full update lifecycle FSM |
| `lib/features/updater/presentation/widgets/settings_sheet.dart` | Settings modal: server info, version, channel selection, update status |
| `lib/features/updater/presentation/widgets/update_prompt_dialog.dart` | Update prompt: release notes, download progress, SHA-256 badge, install |
| `android/app/src/main/kotlin/.../MainActivity.kt` | MethodChannel handler: `getAppInfo`, `canInstallUnknownPackages`, `installApk` |
| `android/app/src/main/AndroidManifest.xml` | `REQUEST_INSTALL_PACKAGES` + FileProvider for APK installation |
| `android/app/build.gradle.kts` | Release signing: external keystore, env-var fallback, v1+v2 signing |
| `android/app/src/main/res/xml/update_paths.xml` | FileProvider cache paths for update APKs |
| `scripts/publish_update.py` | Publication CLI: monotonic versionCode, SHA-256, atomic manifest+APK |
| `updates/version_registry.json` | Global monotonic versionCode registry (tracked in Git) |
| `app/routes/api.py` | Server endpoints: `/api/app/update`, `/api/app/download` |
| `app/config.py` | `UPDATES_DIR` env-driven path |
| `tests/test_app_updates.py` | Backend tests: channel validation, manifest serving, byte-range download |
| `test/features/updater/` (4 files) | Flutter tests: manifest validation, controller lifecycle, settings UI |

### Channel Switching Behavior

- User selects channel via **SettingsSheet** → confirmation dialog → persists to `SharedPreferences`
- Compile-time default (`--dart-define=APP_CHANNEL=...`) is initial default only; runtime persistence is authoritative
- **Downgrade protection:** If Dev 103 is installed and user switches to Production, manifest rejects Production 100 (versionCode <= installed). User stays on current build until Production 104+ is published.
- Auto-check throttled to every 4 hours; manual checks always allowed.

### VersionCode Strategy

- **Global monotonic sequence** shared by both channels
- Registry at `updates/version_registry.json` (current: `lastVersionCode: 105`, developer
  `1.0.5-dev.105` — 104 and 105 were published during the 2026-09-27 device verification)
- **The APK is the source of truth.** `publish_update.py` reads the built APK's own
  `packageId`/`versionCode`/`versionName`/`minSdk`/`targetSdk` back with `aapt2` and refuses to
  publish unless they match the manifest it is about to write — a mismatched pair is rejected
  loudly, never "corrected".
- Releases are produced by **`scripts/release_android.py`**, which allocates the next versionCode,
  builds with `--build-name/--build-number`, re-reads the APK identity, and then publishes. Build
  and manifest therefore cannot drift apart.
- `pubspec.yaml` carries `1.0.3+103`: the floor, not the next release. A plain
  `flutter build apk --release` produces a *lower* versionCode than anything published, and a test
  (`ReleaseToolingTests.test_pubspec_build_number_cannot_outrun_the_published_registry`) keeps it
  that way.
- **Not based on git commit count** — managed explicitly, and gated by the release script.

### Signing

- External keystore: `~/.android/media_server_release.keystore` (alias `media_server_key`)
- Config priority: `key.properties` (git-ignored, lives at `flutter_client/android/key.properties`)
  → env vars (`MEDIA_SERVER_KEYSTORE_PATH/_PASSWORD`, `MEDIA_SERVER_KEY_ALIAS/_KEY_PASSWORD`)
  → **fail closed**. No credential is stored in `build.gradle.kts`, and a release build with no
  keystore fails with a message instead of silently producing a debug-signed APK that can never be
  installed as an update. `MEDIA_SERVER_ALLOW_DEBUG_SIGNING=1` is the explicit escape hatch for
  throwaway builds.
- v1 (JAR) + v2 (APK Signature Scheme) explicitly enabled
- Keystores and `key.properties` excluded via `.gitignore` (root, `flutter_client/`, and
  `flutter_client/android/`)
- ⚠️ The old password literal is still present in **git history** (it was committed in
  `build.gradle.kts` before this pass). The keystore file itself was never committed, so it is not
  exploitable on its own, but treat that password as known: rotate the keystore only if the `.jks`
  itself is ever suspected of leaking (rotating the key breaks updates for installed builds).

### Known Limitations (Pre-Adoption)

1. Update endpoints (`/api/app/update`, `/api/app/download`) are **unauthenticated**
2. No APK signing certificate pinning (SHA-256 file hash only)
3. No automatic background update checks (WorkManager)
4. No download resume on interruption
5. ~~`minSupportedVersionCode` manifest field not enforced client-side~~ — **now enforced**: an
   install below the declared floor is treated as a required update (the prompt cannot be
   dismissed). Publish the floor with `--min-supported-code`.

---

## Phase 4.4 — Movie Details Screen & Direct Playback Handshake (COMPLETE)

### Key Files

| File | Purpose |
|------|---------|
| `lib/features/library/presentation/screens/movie_details_screen.dart` | Full movie details with backdrop, poster, synopsis, cast rail, tech specs |
| `lib/features/library/data/models/movie_details.dart` | `MovieDetails` response model |
| `lib/features/library/data/models/movie_extended_details.dart` | `MovieExtendedDetails` (cast, tagline, certification) |
| `lib/features/library/data/models/movie_specs.dart` | `MovieSpecs` (codec, resolution, audio) |
| `lib/features/library/data/repositories/library_repository.dart` | `fetchMovieDetails()` via `GET /api/movie/<filename>` |
| `lib/app/routes.dart` | `/movie-details` route with `MovieItem` extra and `?filename=` fallback |

### Navigation Flow

```
ConnectionScreen → LibraryScreen → MovieDetailsScreen → PlayerScreen (production)
       ↕ Settings         ↕ Search/Filter/Sort              ↕ Back to Details
```

---

## Phase 4.3 — Library Search, Sort & Filter (COMPLETE)

### Key Files

| File | Purpose |
|------|---------|
| `lib/features/library/presentation/controllers/library_controller.dart` | `LibraryController` (Riverpod): search debounce, sort, genre filter |
| `lib/features/library/presentation/widgets/sort_filter_sheet.dart` | Bottom sheet: sort mode (A→Z, Year, Rating), genre multi-select |

### Client-Side Processing

- Search: 300ms debounced, case-insensitive substring match on title
- Sort: Alphabetical (A→Z/Z→A), Year (newest first), Rating (highest first)
- Filter: Genre multi-select from dynamically discovered genres
- All filtering/sorting is entirely client-side (no server round-trips)

---

## Phase 4.1-4.2 — Library Data Layer & UI (COMPLETE)

### Backend API Endpoints Added

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/movies` | GET | Returns `{movies: [...], watching: [...], total: N}` |
| `/api/movie/<path:filename>` | GET | Returns `{movie, specs, extended, formatted_runtime, backdrop_tmdb_id, transcode_info}` |

### Key Flutter Files

| File | Purpose |
|------|---------|
| `lib/features/library/data/models/movie_item.dart` | `MovieItem` data model (title, year, rating, genre, poster, runtime) |
| `lib/features/library/data/models/library_response.dart` | `LibraryResponse` wrapper (movies list + watching list) |
| `lib/features/library/data/repositories/library_repository.dart` | `LibraryRepository` fetching via Dio |
| `lib/features/library/presentation/screens/library_screen.dart` | Main library grid with search bar, refresh, settings gear |
| `lib/features/library/presentation/widgets/movie_card.dart` | Poster card with rating badge, year pill |
| `lib/features/library/presentation/widgets/movie_grid.dart` | Responsive grid layout |
| `lib/features/library/presentation/widgets/continue_watching_rail.dart` | Horizontal scrollable "Continue Watching" rail |
| `lib/core/api/api_client.dart` | Added `serverBaseUrlProvider` |
| `lib/core/api/api_endpoints.dart` | Added `movieDetails`, `scan`, `appUpdate`, `appDownload` |
| `lib/core/constants/storage_keys.dart` | Added `updateChannel`, `lastUpdateCheckTime` |
| `lib/core/storage/settings_service.dart` | Added channel persistence, last check time, `activeChannelProvider` |

---

## All Modified Tracked Files (Working Tree)

| File | Why Changed |
|------|-------------|
| `.gitignore` | Exclude keystores and APK artifacts, track `version_registry.json` |
| `app/config.py` | Added `UPDATES_DIR` for update artifacts |
| `app/routes/api.py` | Added `/api/movies`, `/api/movie/<filename>`, `/api/app/update`, `/api/app/download` |
| `flutter_client/.gitignore` | Exclude keystores, `key.properties`, `local.properties` |
| `flutter_client/android/app/build.gradle.kts` | Release signing config |
| `flutter_client/android/app/src/main/AndroidManifest.xml` | `REQUEST_INSTALL_PACKAGES` + FileProvider |
| `flutter_client/android/app/src/main/kotlin/.../MainActivity.kt` | MethodChannel bridge for update installation |
| `flutter_client/android/gradle.properties` | JVM heap 8G→3G (host memory constraint) |
| `flutter_client/lib/app/routes.dart` | Added `/library`, `/movie-details` routes |
| `flutter_client/lib/core/api/api_client.dart` | Added `serverBaseUrlProvider` |
| `flutter_client/lib/core/api/api_endpoints.dart` | Added `movieDetails`, `scan`, `appUpdate`, `appDownload` |
| `flutter_client/lib/core/constants/storage_keys.dart` | Added `updateChannel`, `lastUpdateCheckTime` |
| `flutter_client/lib/core/storage/settings_service.dart` | Added channel/check-time persistence |
| `flutter_client/lib/features/connection/presentation/connection_screen.dart` | Added "Browse Movie Library" button |
| `flutter_client/pubspec.yaml` | Added `crypto: ^3.0.3`, `path_provider: ^2.1.2` |
| `flutter_client/pubspec.lock` | Lock file update |
| `tests/conftest.py` | Added `UPDATES_DIR` to test isolation |

---

## All New Untracked Files

### Flutter Client
- `flutter_client/android/app/src/main/res/xml/update_paths.xml`
- `flutter_client/lib/core/models/app_channel.dart`
- `flutter_client/lib/features/library/` (13 files — data models, repository, controllers, screens, widgets)
- `flutter_client/lib/features/updater/` (6 files — data models, repository, bridge, controller, UI widgets)
- `flutter_client/test/features/library/` (library tests)
- `flutter_client/test/features/updater/` (4 test files)

### Backend
- `scripts/publish_update.py`
- `tests/test_app_updates.py`
- `tests/test_movies_api.py`
- `updates/version_registry.json`
- `updates/.gitkeep`

---

## Phase 4.6 & 4.7 Completed Status

### Phase 4.6 — Persistent Navigation Shell & Settings Integration (COMPLETE)
1. **Persistent Navigation Shell (`AppShell`):** `StatefulShellRoute.indexedStack` with 3 primary destinations: Home, Library, and Settings.
2. **Settings Screen:** Fullscreen settings screen with active server base URL, device identity, update channel selector, manual update checker, and brand intro replay.
3. **Presence Telemetry:** Automatic client heartbeat registration (`features/devices/presentation/controllers/device_presence_controller.dart`).

### Phase 4.7 — Fire TV Stick 4K & Universal Android APK (COMPLETE)
1. **Universal APK (`in.anisparvez.media_server_client`):** Single binary for both Android mobile touch devices and Android TV / Fire TV Stick 4K 10-foot remote devices.
2. **Collapsible Obsidian Side Rail (`TvSideNavigationRail`):** 68dp collapsed / 220dp expanded side navigation rail replacing bottom navigation on TV mode.
3. **Borderless Fullscreen TV Cinema Player:** Automatically removes portrait split-view on TV, mapping D-pad remote transport keys (Play/Pause, Rewind, Fast Forward, Seek ±10s).
4. **Pass 2 Refinements (Focus Traversal & Debounced Exit):**
   - **Debounced Double-Back & Root Exit Focus Trap:**
     - Converted `TvExitDialog` to a stateful dialog with an internal `_isShowing` static guard, `barrierDismissible: false`, and a 350ms dismissal gate (`_canDismissOnBack`).
     - Added 350ms debounce (`_lastBackTime`) to `AppShell._handleBack(context)`.
     - Trapped initial focus on "Cancel" with red obsidian glow (`AppColors.brandRed`), D-pad Right navigating to "Exit". Back press cancels without exiting.
   - **Directional Traversal Bridge (`TvDirectionalFocusAction`):**
     - Wrapped content area in `Actions(actions: { DirectionalFocusIntent: TvDirectionalFocusAction(...) })`.
     - Intercepts boundary traversal when `focusInDirection(TraversalDirection.left)` returns `false` at column 0.
     - Automatically routes focus to `tvRailFocusNodesProvider[currentIndex]` and expands `TvSideNavigationRail` (68dp to 220dp).
   - **Rail-to-Content Focus Restoration:**
     - Pressing D-pad Right on an expanded rail item collapses the rail back to 68dp and restores focus cleanly to the active content card.
     - Stripped `escape` and `goBack` handlers from `_TvRailItem.onKeyEvent` so back events bubble exclusively to `AppShell._handleBack()`.
   - **TV Settings 10-Foot Architecture:**
     - Clean single "Settings" heading on TV (omitting redundant top branding/logo).
     - Full-width focusable cards for Server Connection, Device ID, and Update Channel options with red active glow borders.
     - Wrapped switches (`Switch.adaptive`) in `ExcludeFocus` to eliminate focus traps.
   - **TV Remote Player Polish:**
     - Bound 2-zone remote transport model.
     - Eliminated D-pad Up/Down volume manipulation on TV to prevent conflicts with native HDMI-CEC TV hardware volume.
     - Back key hierarchy: first Back dismisses visible on-screen controls; second Back stops playback, flushes watch progress, and returns to Movie Details.

### Known Observations & Technical Focus for Next Session
1. **Remote Back Button Twin-Dispatch & Exit Dialog Dismissal:**
   - Physical Android TV remotes generate both a Flutter key event (`KeyDownEvent: goBack`) and an OS activity callback (`handlePopRoute`).
   - The current 350ms gate in `TvExitDialog` ensures that rapid twin events or accidental double-taps do not instantly dismiss the dialog.
   - *Observation for Next Session:* If the user wants the dialog to **never** dismiss on Back (strictly requiring D-pad selection of "Cancel" or "Exit"), `_canDismissOnBack` can be removed in favor of explicit button selection only (`Navigator.of(context).pop(false)` on Cancel).
2. **Video Player Buffering & Transcoding Latency on Fire TV:**
   - Fire TV Stick 4K communicates over LAN Wi-Fi to Waitress (`http://192.168.1.16:8000`).
   - Direct-playable MP4/AAC streams (*Batman: Knightfall*) start within 1-2s. MKV/HEVC streams requiring dual-GPU HLS chunked transcoding (AMD Vega 8 + RX 560X) require 3-5s for chunk 0/1 encoding and segment delivery.
   - *Observation for Next Session:* If stream buffering persists on specific media (*Coyote vs. Acme*), inspect server transcode logs (`cache/hls/`) or media container codec parameters via `/api/media-info/<filename>`.
3. **Focus Traversal & Viewport Auto-Scroll:**
   - In `TvFocusable`, viewport auto-scroll uses `keepVisibleAtEnd` when `alignment` is null.
   - Ensure that rapidly scrubbing through long movie grids or settings cards keeps the focused card centered without jarring scroll leaps.
4. **Player Remote Scrubbing & Controls Fade:**
   - Pressing D-pad Left/Right in `PlayerScreen` scrubs ±10s. If controls fade out after 4s of inactivity during scrubbing, verify that subsequent D-pad clicks smoothly resurrect the HUD.

---

## Running the Flutter Client

### Android (primary target)
```powershell
cd E:\MediaServer\flutter_client
# Debug on physical device
& "D:\src\flutter\bin\flutter.bat" run -d <device-id>
# Release APK build
& "D:\src\flutter\bin\flutter.bat" build apk --release
# Install on device
adb install build\app\outputs\flutter-apk\app-release.apk
# Direct-to-player intent (bypasses connection screen)
adb shell am start -n in.anisparvez.media_server_client/.MainActivity --es route "/player"
```

### Windows (secondary target)
```powershell
cd E:\MediaServer\flutter_client
& "D:\src\flutter\bin\flutter.bat" run -d windows --release
```

### Testing
```powershell
cd E:\MediaServer\flutter_client
& "D:\src\flutter\bin\flutter.bat" test                    # 120 tests
& "D:\src\flutter\bin\flutter.bat" analyze lib test         # Static analysis
```

### Backend Testing
```powershell
cd E:\MediaServer
.\venv\Scripts\python.exe -m pytest tests/                  # 239 tests
```

### Publishing an Update

The APK must be built with the versionCode that will be published, so build and publish are one
step:

```powershell
cd E:\MediaServer
.\venv\Scripts\python.exe scripts\release_android.py --channel developer --version 1.0.5-dev.105 `
    --notes "What changed"
# add --dry-run to build and verify without publishing, or
# --apk <path> to publish an already-built APK (still identity-verified)
```

The script allocates the next versionCode from `updates/version_registry.json`, runs
`flutter build apk --release --build-name=<version> --build-number=<code>`, reads the APK's own
identity back with `aapt2`, and only then publishes (APK + manifest + registry, atomically).

`scripts/publish_update.py` remains available for a pre-built APK and applies the same
verification — it refuses any APK whose versionCode/versionName/packageId/minSdk/targetSdk do not
match the manifest it is about to write.

---

## Earlier Phases (Reference)

### Phase 1 — Flutter Client Foundation (DONE)
- `flutter_client/` project structure, `lib/core/`, connection screen, device identity
- Committed: `5b0b1fa`, `eadb257`

### Phase 2 — Video Player POC (DONE)
- `PlayerControllerInterface` abstraction over `media_kit`/`libmpv`
- All 6 stages (2A–2F) verified LAN & WAN; committed `f8e8c23`
- Test candidates: Batman (Direct MP4), Spider-Man (HLS), Lust Stories (SRT subs), I Want Your Sex (HEVC 10-bit)

### Phase 3A — Production Player Core Architecture (DONE)
- `flutter_client/lib/features/player/` with domain/infrastructure/presentation layers
- `PlayerScreen`, `PlayerControlsOverlay`, `PlayerSurface`, `DoubleTapSeekDetector`

### Phase 3B — Android-First Timeline & Live Seek Preview (DONE)
- `VideoTimelineBar` with decoupled scrubbing, `SeekPreviewController` with debounce/race protection
- Committed `2e95246`

### Phase 3C — Audio & Subtitle Track Selectors, Speed & Controls Polish (DONE)
- `PlaybackSpeedSheet`, `AudioTrackSheet`, `SubtitleTrackSheet`, `PlayerHudToast`
- Transparent controls overlay, equidistant seekbar, direct intent routing
- 58/58 tests, 0 analyzer issues

### Android Physical Device Setup (DONE)
- Vivo I2217 (Android 16, API 36), wireless ADB
- `media_kit_libs_android_video: ^1.3.8` for `libmpv.so`
