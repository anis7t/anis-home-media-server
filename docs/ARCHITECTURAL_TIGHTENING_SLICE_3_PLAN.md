# Implementation Plan — Architectural Tightening Slice 3

## Title & Metadata
- **Slice**: Slice 3 (Flutter Client Layer Standardization, State Unification & Asset Tightening)
- **Origin Directive**: Argon Architecture Review (`argon-review`)
- **Author**: Antigravity
- **Date**: 2026-10-25
- **Branch**: `feat/argon-architectural-revamp`

---

## 1. Scope

### In Scope
1. **Standardize Feature Folder Structure Across All 12 Features in `flutter_client/lib/features/`**:
   - `admin`: Replace `infrastructure/` with `data/` (`admin_repository.dart`). Maintain `domain/models/` and `presentation/`.
   - `auth`: Replace `infrastructure/` with `data/` (`auth_repository.dart`, `auth_secure_storage.dart`, `oauth_launcher_service.dart`, `qr_auth_repository.dart`). Maintain `domain/models/` and `presentation/`.
   - `cast`: Standardize `data/models/cast_device.dart` into `domain/models/cast_device.dart`. Keep `data/repositories/cast_repository.dart` and `presentation/`.
   - `connection`: Move `models/connection_state.dart` to `domain/models/`, `controllers/connection_controller.dart` to `presentation/controllers/`, and `presentation/connection_screen.dart` to `presentation/screens/`.
   - `devices`: Standardize `data/repositories/device_repository.dart` and `presentation/`.
   - `home`: Maintain `domain/models/genre_section.dart` and `presentation/` (`controllers/`, `screens/`, `widgets/`). Add shared catalog data bridge.
   - `intro`: Replace `infrastructure/` with `data/` (`audioplayers_score.dart`, `intro_video_player.dart`). Maintain `domain/` and `presentation/`.
   - `library`: Move `data/models/` (`library_response.dart`, `movie_details.dart`, `movie_extended_details.dart`, `movie_item.dart`, `movie_specs.dart`) to `domain/models/`. Keep `data/repositories/library_repository.dart` and `presentation/`.
   - `player`: Replace `infrastructure/` with `data/` (`media_kit_player_adapter.dart`, `media_volume_service.dart`, `player_media_resolver.dart`, `screen_brightness_service.dart`). Move `application/playback_progress_reporter.dart` into `presentation/controllers/` (or `domain/`). Keep `domain/` and `presentation/`.
   - `settings`: Add `presentation/widgets/` receiving `settings_content.dart` and `settings_sheet.dart` from `updater`.
   - `shell`: Maintain `presentation/screens/` and `presentation/widgets/`.
   - `updater`: Relocate `settings_content.dart` and `settings_sheet.dart` to `settings/presentation/widgets/`. Move `data/models/update_manifest.dart` to `domain/models/`. Move `infrastructure/app_installer_bridge.dart` to `data/bridges/`. Keep `presentation/controllers/update_controller.dart` and `presentation/widgets/update_prompt_dialog.dart`.
2. **Untangle `settings` UI from `updater`**:
   - `settings_content.dart` and `settings_sheet.dart` moved from `updater/presentation/widgets/` to `settings/presentation/widgets/`.
   - `settings_screen.dart` and all callers updated to import from `features/settings/`.
   - Tests `flutter_client/test/features/updater/settings_sheet_test.dart` and `settings_screen_test.dart` updated.
3. **Unify Catalog & Progress State between `home` and `library`**:
   - Ensure `home_feed_controller.dart` (`features/home/`) and `library_controller.dart` (`features/library/`) share a single Riverpod catalog and progress state source backed by `library_repository.dart`.
   - Guarantee zero redundant network requests when switching between `HomeScreen` and `LibraryScreen` or opening drawers and rails.
4. **Compress Bundled Intro Audio**:
   - Transcode `flutter_client/assets/audio/intro-theme.wav` (541 KB) to high-bitrate AAC `intro-theme.m4a` (102 KB) at 256 kbps, 44.1 kHz stereo, saving > 80% bundle size.
   - Update `pubspec.yaml`, `audioplayers_score.dart`, and `intro_asset_test.dart`.

### Deliberately Out of Scope
- Backend changes in `rust/` (completed and locked in Slice 2).
- Web client changes in `web/` (deferred to Slice 4).
- Altering the opening sequence timing, visual shaders, or animation duration (3.07s duration preserved).
- Removing or altering any user-facing settings functionality or updater prompt behavior.

---

## 2. Exit Criteria
- `flutter analyze` inside `flutter_client/` passes with **0 issues, 0 errors, 0 warnings**.
- `powershell -ExecutionPolicy Bypass -File scripts/run_flutter_tests.ps1` runs all test suites and reports **100% passing tests**.
- `intro-theme.wav` is replaced by `intro-theme.m4a` in `pubspec.yaml`, `audioplayers_score.dart`, and asset directory, cutting bundle size by over 400 KB.
- `settings_content.dart` is located in `flutter_client/lib/features/settings/presentation/widgets/`.

---

## 3. Risks & Mitigations
- **Broken Imports across Flutter features**:
  - *Risk*: Moving classes across `domain`, `data`, and `presentation` can break relative or package imports in screens and tests.
  - *Mitigation*: Perform automated refactorings with systematic import updates, followed by full project-wide `flutter analyze` verification.
- **Intro Audio Playback Format Compatibility**:
  - *Risk*: `audioplayers` must decode the compressed intro asset seamlessly across all target Android devices (including older Fire TV sticks).
  - *Mitigation*: Use standard AAC-LC in MP4 container (`.m4a`), universally supported by Android MediaPlayer from API level 1+ without requiring external codecs.
- **Shared Riverpod State Invalidation**:
  - *Risk*: Unifying home and library state could cause inadvertent rebuild loops or stale continue-watching items.
  - *Mitigation*: `HomeFeedController` continues to derive its feed reactively from `libraryControllerProvider` while preserving local lazy rail pagination.

---

## 4. Open Decisions
- **Audio Format Choice**: AAC-LC in `.m4a` container (256 kbps) is chosen as recommended because Android's native MediaPlayer / MediaCodec supports AAC out of the box on 100% of Android devices including Fire TV Stick 4K, whereas Opus in `.ogg` has container quirks in older Android media framework versions.

---

## 5. Execution Steps

1. **Step 1: Audio Compression & Pubspec Update**
   - Transcode `flutter_client/assets/audio/intro-theme.wav` to `flutter_client/assets/audio/intro-theme.m4a` using `ffmpeg` with `-c:a aac -b:a 256k`.
   - Remove `intro-theme.wav` and update `flutter_client/pubspec.yaml`.
   - Update `flutter_client/lib/features/intro/infrastructure/audioplayers_score.dart` (or new data path) to reference `audio/intro-theme.m4a`.
   - Update `flutter_client/test/features/intro/intro_asset_test.dart` to assert `.m4a` format, length, and presence.
2. **Step 2: Settings UI Untangling**
   - Move `flutter_client/lib/features/updater/presentation/widgets/settings_content.dart` and `settings_sheet.dart` to `flutter_client/lib/features/settings/presentation/widgets/`.
   - Update internal imports in `settings_content.dart`, `settings_sheet.dart`, `settings_screen.dart`, and `app_shell.dart`.
   - Update `flutter_client/test/features/updater/settings_sheet_test.dart` and `flutter_client/test/features/settings/settings_screen_test.dart`.
3. **Step 3: Standardize 12 Feature Layers (`domain/`, `data/`, `presentation/`)**
   - Refactor `admin`, `auth`, `cast`, `connection`, `devices`, `home`, `intro`, `library`, `player`, `settings`, `shell`, and `updater`.
   - Move models from `data/models/` into `domain/models/` for `cast`, `library`, `updater`.
   - Rename `infrastructure/` to `data/` across `admin`, `auth`, `intro`, `player`, `updater`.
   - Move controllers and screens into `presentation/controllers/` and `presentation/screens/` across `connection` and `player`.
4. **Step 4: Catalog & Progress State Synchronization**
   - Audit and confirm `home_feed_controller.dart` and `library_controller.dart` reactively share `library_repository.dart` and cache data without duplicate network calls.
5. **Step 5: Project-Wide Import Updates & Static Analysis**
   - Update all import statements in `flutter_client/lib/` and `flutter_client/test/`.
   - Run `flutter analyze` inside `flutter_client/`.
6. **Step 6: Test Suite Execution & Walkthrough Documentation**
   - Run `powershell -ExecutionPolicy Bypass -File scripts/run_flutter_tests.ps1`.
   - Write `docs/ARCHITECTURAL_TIGHTENING_SLICE_3_WALKTHROUGH.md` and commit Slice 3.
