# Implementation Plan: Upgrade CI `setup-java` to v5, `node.js` to v24, Rebuild Production Binaries & Client APK

**Date:** 2026-11-22  
**Target:** CI Pipeline (`.github/workflows/ci.yml`), Documentation (`docs/`), Frontend Environment (`web/`), and Android Client Release (`updates/production/`)  
**Status:** DRAFT (Awaiting User Approval)

---

## 1. Executive Summary & Objective

Modernize the GitHub Actions CI pipeline and project dependencies to eliminate deprecation warnings, ensure long-term runner stability, rebuild all production binaries (Rust backend, React frontend, Android client APK `v1.4.12`), and verify that all 4 CI pillars pass with zero warnings:

1. **`actions/setup-java` Upgrade**: Upgrade from deprecated `v4` (`cf277c6`) to `v5`, switching the internal action runner engine to Node 24 and enabling enhanced toolchain verification.
2. **Node.js Environment Upgrade**: Upgrade the CI frontend runtime to Node.js 24 (`node-version: 24`), aligning with `web/package.json` (`@types/node: ^24.13.3`).
3. **Documentation & Requirement Updates**: Synchronize `docs/TESTING.md`, `docs/WINDOWS_SETUP.md`, and `docs/PROJECT_STATUS.md` with the new toolchain baselines.
4. **Production Rebuild & Release**:
   - Rebuild React 19 production distribution (`web/dist/`).
   - Rebuild and deploy native Rust backend binary (`media-server-api.exe`).
   - Build, package, and publish Android production client APK `v1.4.12` (versionCode `158`) via `scripts/release_android.py`.
5. **CI Verification**: Commit and push to `main`, validating that all 4 GitHub Actions status checks pass cleanly.

---

## 2. Scope of Changes

### What Changes:
1. **GitHub Actions Workflow (`.github/workflows/ci.yml`)**:
   - In `frontend` job: Update step name to `Setup Node.js 24` and set `node-version: 24`.
   - In `flutter` job: Upgrade `actions/setup-java` to `v5` (`actions/setup-java@v5`).
2. **Project Documentation & Requirements**:
   - `docs/TESTING.md`: Update CI matrix table for `frontend` (`Node.js 24`) and `flutter` (`setup-java@v5`).
   - `docs/WINDOWS_SETUP.md`: Update Node.js runtime recommendations (Node.js 20+ / 24+ LTS).
   - `docs/PROJECT_STATUS.md`: Log the toolchain upgrade, production release `v1.4.12`, and clean CI verification.
3. **Production Artifacts Rebuild & Publication**:
   - Compile React 19 frontend bundle (`web/dist/`) via `npm run build`.
   - Compile and deploy production Rust binary (`media-server-api.exe`) via `scripts/deploy_dual_gpu_service.ps1`.
   - Build and publish production Android APK `v1.4.12` (versionCode `158`) via:
     ```bash
     python scripts/release_android.py --channel production --version 1.4.12 --notes "Upgraded CI toolchain to Java v5 & Node 24, with sweeper auto-recovery and multi-GPU lane separation."
     ```
   - Automatically synchronizes `updates/production/manifest.json`, `updates/version_registry.json`, and `updates/production/media-server-client.apk`.

### What Deliberately Does Not Change:
- Java runtime version remains Java 17 Temurin (the canonical LTS version required by Android Gradle Plugin / Flutter toolchain).
- The 4-pillar branch protection architecture (`Rust Backend`, `React Frontend`, `Flutter Client`, `Secrets Scan`) remains identical.
- Flutter framework version remains `stable`.

---

## 3. Exit Criteria

1. **Local Verification**:
   - `npm --prefix web run typecheck`, `npm --prefix web run lint`, `npm --prefix web run test`, and `npm --prefix web run build` execute cleanly.
   - `cd flutter_client && flutter analyze && flutter test` pass with 0 errors.
   - `cargo test --manifest-path rust/Cargo.toml --test integration -- ops::job_queue_test` passes.
2. **Production Release Artifacts Stamped**:
   - Production APK `updates/production/media-server-client.apk` generated and verified via `aapt2` with `versionCode: 158` and `versionName: 1.4.12`.
   - `updates/production/manifest.json` sha256 matches the generated APK byte-for-byte.
3. **CI Pipeline Validation**:
   - Commit pushed to `origin/main`.
   - GitHub Actions CI workflow triggers and all 4 checks pass green:
     - `Secrets & Security Scan`
     - `Rust Backend (Axum)`
     - `React 19 Frontend (SPA)` (running on Node.js 24)
     - `Flutter Client (Android / TV)` (running on setup-java v5)
   - Zero deprecation warnings regarding `setup-java v4`.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Node.js 24 breaking changes with Vite / Vitest / Oxlint** | CI build failure | Tested against `@types/node` 24.x and Vitest 4.x. Local verification via `npm run verify` catches any compatibility issues before pushing. |
| **`setup-java@v5` compatibility with Gradle wrapper** | Android build failure in CI | Java version remains pinned to `17` (`temurin`), which Gradle 8.x and AGP natively support; `v5` only changes the action runner container to Node 24. |
| **APK version registry drift** | Update manifest mismatch | `scripts/release_android.py` enforces single-source-of-truth validation: reads APK headers with `aapt2` before committing manifest and registry updates. |

---

## 5. Implementation Phases & Steps

- **Phase 1: Local Environment & Dependency Verification**
  - Run frontend typecheck, lint, and Vitest test suite on Node 24/25.
  - Run Flutter static analysis and test suite.
- **Phase 2: Workflow & Documentation Updates**
  - Update `.github/workflows/ci.yml` (`setup-java@v5` and `node-version: 24`).
  - Update `docs/TESTING.md`, `docs/WINDOWS_SETUP.md`, and `docs/PROJECT_STATUS.md`.
- **Phase 3: Production Binaries & APK Publication**
  - Build React SPA (`web/dist/`).
  - Execute `python scripts/release_android.py` to build and publish `v1.4.12` (`158`).
  - Deploy Rust service binary if needed.
- **Phase 4: Commit, Push & CI Verification**
  - Commit all changes to `main`.
  - Push to GitHub and monitor CI workflow until all 4 pillars report success.
