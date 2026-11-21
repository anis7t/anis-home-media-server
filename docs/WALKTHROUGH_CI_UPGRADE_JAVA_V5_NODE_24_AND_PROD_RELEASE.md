# Walkthrough: CI Upgrade (Java v5 & Node.js 24), Production Rebuild & Android Client Release v1.4.12

**Date:** 2026-11-22  
**Target:** CI Pipeline (`.github/workflows/ci.yml`), Documentation (`docs/`), and Android Client Release (`updates/production/`)  
**Status:** Completed, Verified & Published

---

## 1. Summary of Changes

### A. CI Pipeline Toolchain Modernization (`.github/workflows/ci.yml`)
- **`actions/setup-java` Upgraded to `v5`**:
  - Replaced deprecated `actions/setup-java@v4` with `actions/setup-java@v5`.
  - Upgrades the action's internal execution engine from Node 20 to Node 24 and eliminates the GitHub Actions runner deprecation annotation.
- **Node.js Environment Upgraded to `24`**:
  - Updated the `frontend` job to use `node-version: 24` (upgraded from `22`), aligning with `@types/node: ^24.13.3` in `web/package.json`.

### B. Documentation & Requirement Updates
- **`docs/TESTING.md`**: Updated CI pipeline matrix table with `Node.js 24` for the `frontend` job and `Java 17 (setup-java@v5)` for the `flutter` job.
- **`docs/WINDOWS_SETUP.md`**: Updated Node.js requirement baseline to `Node.js 24+ LTS (minimum 20+)`.
- **`docs/PROJECT_STATUS.md`**: Documented the toolchain upgrade, production rebuild, and client release `v1.4.12`.

### C. Production Rebuild & Android Client Release v1.4.12
- Rebuilt React 19 production distribution (`web/dist/`) via `npm run build` in 2.32s.
- Executed `scripts/release_android.py` to build and publish production release `v1.4.12` (versionCode `158`):
  - Verified package identity via `aapt2`: `package=in.anisparvez.media_server_client`, `versionCode=158`, `versionName=1.4.12`, `minSdk=24`, `targetSdk=36`.
  - Verified SHA-256 hash: `a1da34a60b5678de16d09ec413f9be115d2bd0d6989b7a50c038cd3465438337`.
  - Atomically updated `updates/production/manifest.json` and `updates/version_registry.json`.

---

## 2. Test Outcomes & Verification Results

1. **Frontend Local Parity Suite (`web/`)**:
   - `npm run typecheck`: Passed with 0 TypeScript errors.
   - `npm run lint`: Passed with 0 oxlint errors.
   - `npm run test`: **46 test files / 338 tests passed** in Vitest.
   - `npm run build`: Production bundle built cleanly into `web/dist/`.
2. **Flutter Local Parity Suite (`flutter_client/`)**:
   - `flutter analyze`: **No issues found** (0 warnings, 0 errors).
   - `flutter test`: **433 tests passed** with 13 intentional offline skip guards.
3. **Rust Backend Local Parity Suite (`rust/`)**:
   - `cargo test --test integration -- ops::job_queue_test`: 17/17 tests passed.
   - `cargo fmt --check` and `cargo clippy`: Passed with 0 warnings.
