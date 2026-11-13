# Implementation Plan: Flutter SDK Upgrade & Dependency Migration

**Document Path:** `docs/PLAN_FLUTTER_SDK_UPGRADE_AND_DEPENDENCY_MIGRATION.md`  
**Date:** 2026-11-14  
**Status:** Pending User Approval  

---

## 1. Context & Objectives

GitHub Actions CI (`Flutter Client (Android / TV)`) failed on commit `b9778d2` because the CI runner downloaded the latest Flutter stable release (3.50.0), which introduced stricter analyzer diagnostics and deprecation warnings, while local development was running on Flutter 3.47.7.

Per user confirmation, we will:
1. Safely upgrade the local Flutter SDK installation (`D:\src\flutter`) from 3.47.7 to the latest stable release (3.50.x).
2. Protect the critical local Windows SDK patch in `packages/flutter_tools/lib/src/windows/visual_studio.dart`.
3. Upgrade `flutter_client` dependencies (`flutter pub upgrade`).
4. Resolve all static analysis diagnostics and verify the complete test suite.
5. Push the aligned codebase and verify green CI on GitHub Actions.

---

## 2. Scope

### In Scope
- **Flutter SDK Upgrade (`D:\src\flutter`):**
  - Extract and backup the local Windows 10 SDK detection patch (`D:\WindowsKits\10`) to `docs/flutter-winsdk-location-patch.diff`.
  - Stash the patch, pull latest stable Flutter (`flutter upgrade`), and re-apply the patch.
  - Rebuild `flutter_tools` and verify `flutter doctor`.
- **Dependency Upgrades (`flutter_client/`):**
  - Run `flutter pub upgrade` to update compatible dependency versions in `pubspec.lock`.
- **Static Analysis & Code Alignment:**
  - Run `flutter analyze` on the upgraded SDK.
  - Resolve deprecation warnings or adjust `flutter_client/analysis_options.yaml` to ensure clean static analysis without spurious failures.
- **Test Suite Verification:**
  - Run `.\scripts\run_flutter_tests.ps1` to ensure all 50+ widget, progress persistence, player, and TV navigation tests pass.
- **CI Workflow & Repository Updates:**
  - Update `.github/workflows/ci.yml` if necessary to maintain exact version alignment.
  - Commit, push, and verify that the GitHub Actions `Flutter Client (Android / TV)` job turns green.

### Out of Scope / Deliberately Preserved
- Android Gradle Plugin / NDK configurations (`minSdk 24`, `targetSdk 36`).
- App package name (`in.anisparvez.media_server_client`) and release signing keys.
- Rust Axum backend server, React SPA, and database schema.

---

## 3. Step-by-Step Implementation Flow

### Step 1: Backup and Stash the Local Flutter SDK Patch
- Generate patch backup:
  ```powershell
  git -C D:\src\flutter diff -- packages/flutter_tools/lib/src/windows/visual_studio.dart > E:\MediaServer\docs\flutter-winsdk-location-patch.diff
  ```
- Stash the uncommitted modification:
  ```powershell
  git -C D:\src\flutter stash push -- packages/flutter_tools/lib/src/windows/visual_studio.dart
  ```

### Step 2: Execute Flutter SDK Upgrade
- Run `flutter upgrade` from `D:\src\flutter`.
- Re-apply the patch:
  ```powershell
  git -C D:\src\flutter stash pop
  ```
- Force tool rebuild and verify:
  ```powershell
  Remove-Item D:\src\flutter\bin\cache\flutter_tools.stamp -ErrorAction SilentlyContinue
  flutter doctor
  ```

### Step 3: Upgrade Client Dependencies
- In `flutter_client/`:
  ```powershell
  flutter pub upgrade
  ```
- Inspect updated `pubspec.lock` diff.

### Step 4: Resolve Analysis Diagnostics
- Run `flutter analyze`.
- If transitive packages (e.g. `material_ui` via `go_router`) trigger deprecation warnings on Material imports, update `analysis_options.yaml` to silence or adjust the specific lint rule:
  ```yaml
  analyzer:
    errors:
      deprecated_member_use: warning # or info / ignore for transitive fix-data
  ```
- Re-run `flutter analyze` until `No issues found!` is achieved.

### Step 5: Run Full Flutter Test Suite
- Run `.\scripts\run_flutter_tests.ps1`.
- Verify 100% pass rate across home feed, library, player, and TV navigation suites.

### Step 6: Commit, Push & Verify CI
- Commit all changes with `chore(flutter): upgrade flutter sdk to 3.50.x and resolve analyzer diagnostics`.
- Push to `main`.
- Monitor GitHub Actions CI run via `gh run watch` to confirm all 4 checks pass.

---

## 4. Exit Criteria

- [ ] `flutter --version` reports 3.50.x on local workstation.
- [ ] `flutter doctor` shows all checks green (`[√]`).
- [ ] `flutter analyze` in `flutter_client` passes with zero errors/warnings.
- [ ] `.\scripts\run_flutter_tests.ps1` completes with all tests passing.
- [ ] GitHub Actions CI workflow passes on `main` across all 4 concurrent jobs.

---

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| Overwriting local Windows SDK patch | High | Backed up to diff file before touching SDK; verified with `flutter doctor`. |
| Deprecation cascades breaking CI | Medium | Test locally with `flutter analyze` before pushing. |
| Test regressions on player/TV components | Medium | Run exhaustive local parity suite (`run_flutter_tests.ps1`). |

---

## 6. Open Decisions

None. All steps follow documented repository procedures from `docs/DEVELOPMENT_STATUS.md`.

