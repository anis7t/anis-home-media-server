# Flutter Client — Phase Status & Handoff

> **Last updated:** 2026-09-26
> **Active branch:** `feat/flutter-production-player`
> **Package ID:** `in.anisparvez.media_server_client`
> **Source conversations:** `8478b150` (Phase 1 & 2), `995057c0` (Phase 2–3C), `fbcf1933` (Phase 4 + Multi-Channel Updates)
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
| 4.6 | Persistent Bottom Navigation & Settings Integration | ✅ COMPLETE — 3-tab shell (Home, Library, Settings), 134/134 tests |

---

## Current State (2026-09-27, after the closure + hardening pass)

**Git status:** `feat/flutter-production-player` — the Phase 4 line is committed in focused commits
(Phase 4.6 closure first, then the hardening fixes; see `docs/PROJECT_STATUS.md` §0).
**Last commit:** `ed6d579 feat(flutter): complete phase 4 navigation shell`

Everything from Phase 4.1–4.6 is committed, and `lib/features/player/` is untouched by the 4.6 work.

### Test Results (verified 2026-09-27)

| Suite | Count | Result |
|-------|-------|--------|
| Flutter tests | 128 passed, 10 skipped | ✅ 0 failures (skips are live-server tests, see below) |
| Flutter analyze (lib + test) | — | ✅ 0 issues |
| Python backend tests | 250 passed, 1 skipped | ✅ 0 failures |
| Production DB across a full suite run | movies / devices / watch history / progress / settings | ✅ byte-identical before vs after |
| Player invariant (`git diff -- flutter_client/lib/features/player/`) | — | ✅ Zero changes |

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

---

## Strict Invariants (MUST preserve)

1. **Player feature untouched:** `flutter_client/lib/features/player/` MUST remain functionally unchanged. No modifications unless a concrete integration requirement makes it necessary.
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

## What Was Being Planned Next (Milestone 4.6)

Before this session ended, the user had expressed intent to continue with **Milestone 4.5** (which was relabeled to **persistent bottom navigation and settings integration**). The planning discussion was not completed. The general direction was:

1. **Persistent bottom navigation bar** replacing the current "connection screen as home" pattern
2. **Tab structure**: Library (home), Settings, possibly Devices
3. **Settings screen** replacing the current bottom-sheet `SettingsSheet` with a full screen
4. **Navigation architecture**: `ShellRoute` or `StatefulShellRoute` wrapping tabbed content

This was **NOT** implemented — only discussed. The next coding model should:
1. Re-read this document and `docs/PROJECT_STATUS.md`
2. Inspect the current git state (`git status`, `git diff --stat`)
3. Verify tests pass before making changes
4. Ask the user whether to continue with the navigation restructure or a different priority

---

## Running the Flutter Client

### Android (primary target)
```powershell
cd C:\MediaServer\flutter_client
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
cd C:\MediaServer\flutter_client
& "D:\src\flutter\bin\flutter.bat" run -d windows --release
```

### Testing
```powershell
cd C:\MediaServer\flutter_client
& "D:\src\flutter\bin\flutter.bat" test                    # 120 tests
& "D:\src\flutter\bin\flutter.bat" analyze lib test         # Static analysis
```

### Backend Testing
```powershell
cd C:\MediaServer
.\venv\Scripts\python.exe -m pytest tests/                  # 239 tests
```

### Publishing an Update

The APK must be built with the versionCode that will be published, so build and publish are one
step:

```powershell
cd C:\MediaServer
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
