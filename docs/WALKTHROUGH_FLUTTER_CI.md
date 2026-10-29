# Walkthrough: Flutter Client CI Pipeline Integration (Android & TV)

## Executive Summary

Continuous Integration for **Anis' Home Media Server** has been expanded from a 2-tier pipeline (`backend` + `frontend`) into a comprehensive **3-Pillar GitHub Actions CI Pipeline**, natively incorporating the Flutter client across Android Phone and Android TV / Fire TV form factors.

The updated pipeline validates every commit to `main` and pull request concurrently across all three client and server tiers:
1. **Rust Backend (Axum 0.8):** Formatting (`cargo fmt`), Clippy linter with zero warnings (`cargo clippy --all-targets -- -D warnings`), synthetic media & app distribution fixtures, and unit + PostgreSQL integration testing (242 tests passing).
2. **React 19 Frontend (SPA):** Clean dependency installation (`npm ci`), TypeScript type checking (`npm run typecheck`), oxlint linting (`npm run lint`), Vitest component tests (`npm run test`), and Vite production bundle compilation (`npm run build`).
3. **Flutter Client (Android Phone & TV):** Java 17 Temurin, Flutter stable with tool cache caching, headless Linux media library support (`libmpv-dev libmpv2`), static analysis and lint rule validation (`flutter analyze`), and the full offline test suite (`flutter test`, 416 tests passing, 13 live tests skipped).

The implementation was committed directly to `main` (commit [`ad8c03d`](https://github.com/anis7t/anis-home-media-server/commit/ad8c03d)) and verified live on GitHub Actions run [40912273999](https://github.com/anis7t/anis-home-media-server/actions/runs/40912273999) with 100% green status across all 3 jobs.

---

## Changes Implemented

### 1. GitHub Actions Workflow Configuration ([`.github/workflows/ci.yml`](file:///e:/MediaServer/.github/workflows/ci.yml))

Added the `flutter` job definition with isolated steps, tool caching, and pinned action hashes:

```yaml
  flutter:
    name: Flutter Client (Android / TV)
    runs-on: ubuntu-latest
    timeout-minutes: 15

    defaults:
      run:
        working-directory: flutter_client

    steps:
      - name: Checkout repository
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - name: Setup Java 17
        uses: actions/setup-java@cf277c60eb25467037889841efdb72551f06f6c3 # v4.4.0
        with:
          distribution: temurin
          java-version: 17

      - name: Setup Flutter (stable)
        uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2 # v2.18.0
        with:
          channel: stable
          cache: true
          cache-key: "flutter-:os:-:channel:-:version:-:arch:-:hash:"
          cache-path: "${{ runner.tool_cache }}/flutter/:channel:-:version:-:arch:"

      - name: Install system dependencies (libmpv)
        run: |
          sudo apt-get update
          sudo apt-get install -y libmpv-dev libmpv2

      - name: Install dependencies (flutter pub get)
        run: flutter pub get

      - name: Verify static analysis (flutter analyze)
        run: flutter analyze

      - name: Run Flutter unit & widget tests
        run: flutter test
```

### 2. Cross-Platform Test Isolation & Determinism Fixes

During the initial CI execution on Ubuntu Linux runners, three subtle cross-platform differences were detected and resolved:

1. **Linux Filesystem Inode Iteration Order ([`intro_asset_test.dart`](file:///e:/MediaServer/flutter_client/test/features/intro/intro_asset_test.dart)):**
   - *Issue:* `Directory('assets').listSync(recursive: true)` returns files according to filesystem directory entry order. On Windows NTFS, audio files were listed before video files, whereas on Linux ext4, video files preceded audio files.
   - *Fix:* Added `..sort()` before asserting the asset list:
     ```dart
     final files = (Directory('assets')
         .listSync(recursive: true)
         .whereType<File>()
         .map((f) => f.path.replaceAll('\\', '/'))
         .toList())
       ..sort();
     ```
2. **Missing Native Media Library in Headless Linux ([`ci.yml`](file:///e:/MediaServer/.github/workflows/ci.yml) & [`app_shell_test.dart`](file:///e:/MediaServer/flutter_client/test/features/shell/app_shell_test.dart)):**
   - *Issue:* `media_kit` dynamically links against `libmpv.so` on Linux. On a bare `ubuntu-latest` runner image, `libmpv` is absent, causing `MediaKit.ensureInitialized()` to throw an initialization exception.
   - *Fix:* Added `sudo apt-get install -y libmpv-dev libmpv2` in the CI pipeline to supply the native dependency, and wrapped `MediaKit.ensureInitialized()` in a defensive `try ... catch` in `app_shell_test.dart` for headless environments.
3. **Live Server Test Guard Parity ([`runtime_player_3a_test.dart`](file:///e:/MediaServer/flutter_client/test/features/player/runtime_player_3a_test.dart)):**
   - *Issue:* While `runtime_player_3b_test.dart` already returned early when `!liveServerTestsEnabled`, `runtime_player_3a_test.dart` called `MediaKit.ensureInitialized()` unconditionally in `setUpAll` and ran test 1 without a skip guard.
   - *Fix:* Added `if (!liveServerTestsEnabled) return;` to `setUpAll` and marked test 1 with `skip: liveServerSkip`, aligning it with tests 2 and 5 and the rest of the live-server test suite.

### 3. Documentation & Project Status

- **Updated [`docs/TESTING.md`](file:///e:/MediaServer/docs/TESTING.md):** Added `flutter` job to the CI Summary table, documented local Flutter verification commands (`flutter pub get`, `flutter analyze`, `flutter test`), and added `Flutter Client (Android / TV)` to the recommended branch protection status checks.
- **Updated [`docs/PROJECT_STATUS.md`](file:///e:/MediaServer/docs/PROJECT_STATUS.md):** Documented the 3-pillar CI foundations and linked the planning and walkthrough documents.
- **Published Implementation Plan [`docs/PLAN_FLUTTER_CI.md`](file:///e:/MediaServer/docs/PLAN_FLUTTER_CI.md):** Formalized plan approved prior to implementation.

---

## Verification & CI Run Results

### Live GitHub Actions Run: [40912273999](https://github.com/anis7t/anis-home-media-server/actions/runs/40912273999)

| Job | Result | Duration | Details |
|---|---|---|---|
| **`Rust Backend (Axum)`** | ✅ **SUCCESS** | 2m 46s | Formatting verified, zero Clippy warnings (`-D warnings`), 242/242 tests passed |
| **`React 19 Frontend (SPA)`** | ✅ **SUCCESS** | 1m 26s | TypeScript clean, oxlint clean, Vitest passed, Vite bundle built |
| **`Flutter Client (Android / TV)`** | ✅ **SUCCESS** | 4m 13s | Zero analyze issues, 416 tests passed, 13 live tests skipped |
| **Overall Pipeline** | ✅ **100% GREEN** | ~4m 15s total | All three application pillars verified simultaneously |
