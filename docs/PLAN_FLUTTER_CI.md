# Implementation Plan: Flutter Client CI Job Integration

**Target Repository:** `anis7t/anis-home-media-server`  
**Target File:** `.github/workflows/ci.yml`  
**Author:** Antigravity  
**Date:** 2026-10-29  

---

## 1. Executive Summary & Objective

The GitHub Actions CI pipeline currently validates the **Rust Backend (Axum)** and **React 19 Frontend (SPA)** across formatting, linting, unit tests, and production bundling. The third primary application surface in this repository is the **Flutter Client (`flutter_client/`)**, targeting Android and Android TV / Fire TV Stick 4K.

Locally, the Flutter client has:
- **`flutter analyze`**: 0 issues (clean static analysis with strict `flutter_lints`).
- **`flutter test`**: 417 passing unit, widget, and domain contract tests (with 12 live-server network tests skipped safely via environment guard).

The objective is to add a concurrent, production-quality `flutter` job to `.github/workflows/ci.yml` that validates the Flutter Android/TV application (`flutter analyze` and `flutter test`) on every push to `main` and pull request targeting `main`.

---

## 2. Scope

### In Scope
1. **GitHub Actions Workflow Job (`flutter`) in `.github/workflows/ci.yml`**:
   - Runs concurrently alongside `backend` and `frontend` jobs.
   - **Runner**: `ubuntu-latest`.
   - **Timeout**: 15 minutes.
   - **Working Directory**: `flutter_client`.
   - **Java Setup**: Pinned `actions/setup-java` with Java 17 (Temurin).
   - **Flutter Setup**: Pinned `subosito/flutter-action` on `stable` channel with dependency caching enabled.
   - **Execution Steps**:
     1. Checkout repository (`actions/checkout`).
     2. Setup Java 17 (`actions/setup-java@v4`).
     3. Setup Flutter (`subosito/flutter-action@v2`) with caching.
     4. Resolve dependencies (`flutter pub get`).
     5. Static analysis (`flutter analyze --fatal-infos`).
     6. Execute test suite (`flutter test`).
2. **Testing Documentation (`docs/TESTING.md`)**:
   - Document the Flutter CI job, local execution commands (`flutter analyze`, `flutter test`), and the distinction between offline automated unit tests vs live hardware/host probes.
3. **Project Status Tracking**:
   - Update `docs/PROJECT_STATUS.md` to reflect three-pillar CI (Rust Backend, React Frontend, Flutter Client).

### Out of Scope (Deliberately Excluded)
- Full release APK compilation (`flutter build apk`) in standard PR CI (retained for manual release workflows or dedicated release tags to preserve GitHub Actions runner minutes).
- Modifying Flutter application code or Dart dependencies.
- Live Android emulator UI integration tests (requires hardware acceleration).

---

## 3. Workflow Design & Invariants

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
        uses: actions/setup-java@8df10395638ca5f45704d4348729f625ae0e56b1 # v4.3.0
        with:
          distribution: temurin
          java-version: 17

      - name: Setup Flutter
        uses: subosito/flutter-action@4389e811389e67d56422e885fa5ecf052d48835d # v2.18.0
        with:
          channel: stable
          cache: true
          cache-key: "flutter-:os:-:channel:-:version:-:arch:-:hash:"
          cache-path: "${{ runner.tool_cache }}/flutter/:channel:-:version:-:arch:"

      - name: Install dependencies (flutter pub get)
        run: flutter pub get

      - name: Verify static analysis (flutter analyze)
        run: flutter analyze

      - name: Run Flutter unit & widget tests
        run: flutter test
```

---

## 4. Exit Criteria

1. `.github/workflows/ci.yml` is updated with the `flutter` job using pinned immutable action commit SHAs.
2. `docs/TESTING.md` documents the Flutter CI job and local replication steps.
3. Commit pushed to `main` (or dedicated PR branch).
4. GitHub Actions run triggers all three jobs (`Rust Backend (Axum)`, `React 19 Frontend (SPA)`, `Flutter Client (Android / TV)`), and all three jobs finish with green checkmarks.

---

## 5. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Flutter Toolchain Download Flakiness** | Ephemeral runner network stalls downloading Flutter SDK. | Invariant enforced: `subosito/flutter-action` enables built-in caching on runner tool cache. |
| **Accidental Live Network Calls in Unit Tests** | Tests fail if localhost or production server is unreachable in CI. | All 417 offline tests already use `TestNetworkGuard` (which fails closed if un-mocked HTTP traffic occurs) and `fake_async` for clock control. 12 live tests are guarded by `MEDIA_SERVER_LIVE_TESTS=1` and skip automatically in CI. |
| **Android Dependency Resolution Overhead** | Unnecessary Gradle sync in analyze/test step. | Running `flutter test` directly on the host JVM/Dart VM does not invoke Gradle or Android SDK compilation. |

---

## 6. Open Decisions for User Approval

- **Workflow Placement**: Add `flutter` as a third concurrent job in `.github/workflows/ci.yml` so that all three client/server surfaces are checked simultaneously.
- **Commit Target**: Commit directly to `main` (since CI is already active on `main`) or open a short branch/PR. (Recommended: direct commit to `main`).
