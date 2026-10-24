# Implementation Plan — Architectural Tightening Slice 1: Workspace Hygiene & Dead-Code Purge

## 1. Overview & Context
This plan specifies the implementation details for **Slice 1** of the architectural tightening directive received from Argon. The goal is to clean up workspace hygiene, eliminate dead proof-of-concept code, remove transient debug artifacts, and consolidate tooling configurations without impacting active production runtime code.

Work is performed on the dedicated branch: `feat/argon-architectural-revamp`.

---

## 2. Scope

### What Changes:
1. **Remove Stray Root & Editor Artifacts:**
   - Delete the stray root artifact `=` left over from earlier session tooling.
   - Delete `.vscode/settings.json.bak` while preserving `.vscode/settings.json`.
2. **Purge Committed Web Debug Captures:**
   - Delete `web/_prng_capture.json`, `web/_prng_capture.mjs`, `web/_tofixed_capture.json`, and `web/_tofixed_capture.mjs`.
   - Update `web/.gitignore` to ignore `_*_capture.*` to prevent accidental future commits.
3. **Consolidate Root Scripts & Python Tooling Configs:**
   - Move `remove_c_mediaserver_stub.cmd` and `run_scrcpy.bat` from the root into `scripts/`.
   - Update `pyrightconfig.json` to explicitly scope Python analysis to `scripts` and `tests/load`.
   - Verify `requirements.txt` remains strictly scoped to verification/release tooling dependencies (`selenium`, `websockets`).
4. **Delete Dead Flutter Player PoC:**
   - Delete `flutter_client/lib/features/player_poc/` (`domain/player_controller_interface.dart`, `domain/seek_preview_controller.dart`, `infrastructure/media_kit_player_adapter.dart`, `presentation/player_poc_screen.dart`).
   - Remove route `/player-poc` and `playerPoc` identifier from `flutter_client/lib/app/routes.dart`.
   - Update import paths in `flutter_client/test/` to resolve directly against canonical production player modules (`flutter_client/lib/features/player/...`):
     - `flutter_client/test/player_controller_interface_test.dart`
     - `flutter_client/test/seek_preview_race_debounce_test.dart`
     - `flutter_client/test/features/player/runtime_player_3a_test.dart`
     - `flutter_client/test/features/player/canonical_player_architecture_test.dart`

### What Deliberately Does NOT Change:
- All documentation in `docs/` and session handoffs in `Handoffs/` remain untouched (backlogged per directive).
- Production player implementation (`flutter_client/lib/features/player/`) is preserved untouched.
- Rust Axum backend code (`rust/`) and React production web code (`web/src/`) remain untouched in Slice 1.
- Production routes (`/player`, `/movie-details`, `/admin`, etc.) remain completely intact.

---

## 3. Exit Criteria
1. `git status --short` confirms:
   - Root files `=`, `.vscode/settings.json.bak`, `remove_c_mediaserver_stub.cmd`, `run_scrcpy.bat` no longer reside at the root.
   - `scripts/remove_c_mediaserver_stub.cmd` and `scripts/run_scrcpy.bat` exist.
   - `web/_prng_capture.*` and `web/_tofixed_capture.*` are removed, and `web/.gitignore` has `_*_capture.*`.
   - `flutter_client/lib/features/player_poc/` is completely removed.
2. `flutter analyze` passes in `flutter_client/` with 0 errors.
3. Flutter test suite passes cleanly: `powershell -ExecutionPolicy Bypass -File scripts/run_flutter_tests.ps1`.
4. Git working tree is clean and committed as `chore(hygiene): execute architectural tightening slice 1 (hygiene & dead-code purge)`.

---

## 4. Risks & Mitigation

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Broken import paths in Flutter tests** | Compilation or test runner failure | Re-route all 4 test imports directly to canonical `package:media_server_client/features/player/...` before deleting the PoC directory, and verify with `flutter test`. |
| **Broken internal path in moved scripts** | Script failure when invoked | `remove_c_mediaserver_stub.cmd` uses `%~dp0` for its temporary list and operates on `C:\MediaServer`; moving to `scripts/` retains `%~dp0ms_stub_list.txt`. `run_scrcpy.bat` uses absolute Winget paths and needs no changes. |
| **Accidental deletion of active editor configs** | Loss of VS Code settings | `.vscode/settings.json` is explicitly preserved; only `.vscode/settings.json.bak` is unlinked. |

---

## 5. Open Decisions
- **Decision 1: Removal of `/player-poc` route in `routes.dart`:**
  - Argon's directive explicitly mandates: *"Ensure `flutter_client/lib/app/routes.dart` and all tests in `flutter_client/test/features/player/` resolve exclusively against `flutter_client/lib/features/player/`"*. We will remove the dead `/player-poc` route from `routes.dart` since `PlayerPocScreen` is being deleted and production uses `/player`.
