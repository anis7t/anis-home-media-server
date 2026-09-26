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
| 4.6 | Persistent Bottom Navigation & Settings Integration | ⏳ NEXT UP (was being planned before session ended) |

---

## Current Working Tree State (2026-09-26)

**Git status:** Uncommitted working tree with cumulative Phase 4 changes on `feat/flutter-production-player`.
**Last commit:** `2d3d597 feat(player): transparent controls overlay, equidistant seekbar layout, right-aligned duration, and direct intent routing`

The working tree contains ALL Phase 4 + Multi-Channel Update changes as unstaged modifications. **Nothing has been committed for Phase 4 yet.**

### Test Results (verified 2026-09-26)

| Suite | Count | Result |
|-------|-------|--------|
| Flutter tests | 121 | ✅ All passed |
| Flutter analyze (lib + test) | — | ✅ 0 issues |
| Python backend tests | 239 | ✅ All passed |
| Player invariant (`git diff -- flutter_client/lib/features/player/`) | — | ✅ Zero changes |

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
- Registry at `updates/version_registry.json` (current: `lastVersionCode: 101`)
- Auto-increment or explicit `--version-code` with strict monotonicity enforcement
- **Not based on git commit count** — managed explicitly via `publish_update.py`

### Signing

- External keystore: `~/.android/media_server_release.keystore`
- Config priority: `key.properties` → env vars (`MEDIA_SERVER_KEYSTORE_*`) → defaults → debug fallback
- v1 (JAR) + v2 (APK Signature Scheme) explicitly enabled
- Keystores, `key.properties` excluded via `.gitignore`

### Known Limitations (Pre-Adoption)

1. Update endpoints (`/api/app/update`, `/api/app/download`) are **unauthenticated**
2. No APK signing certificate pinning (SHA-256 file hash only)
3. No automatic background update checks (WorkManager)
4. No download resume on interruption
5. `minSupportedVersionCode` manifest field not enforced client-side

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
```powershell
cd C:\MediaServer
.\venv\Scripts\python.exe scripts\publish_update.py --channel developer --version 1.1.0-dev.102 --apk path\to\signed.apk --notes "Release notes here"
```

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
