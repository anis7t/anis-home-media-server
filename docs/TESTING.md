# Testing & Continuous Integration Guide

This document describes the testing architecture, local verification commands, and Continuous Integration (CI) pipeline for **Anis' Home Media Server**.

---

## 1. Automated Continuous Integration (GitHub Actions)

The primary CI pipeline is defined in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). It automatically validates code changes on every pull request and commit to `main`.

### Pipeline Summary

| Job | Environment | Target | Checks Performed |
|---|---|---|---|
| **`backend`** | `ubuntu-latest` + `postgres:17-alpine` | Rust Axum (`rust/`) | `cargo fmt --check`<br>`cargo clippy --all-targets -- -D warnings`<br>Synthetic media fixture generation<br>`cargo test --no-fail-fast -- --test-threads=1` |
| **`frontend`** | `ubuntu-latest` + Node.js 22 LTS | React 19 SPA (`web/`) | `npm ci`<br>`npm run typecheck`<br>`npm run lint` (oxlint)<br>`npm run test` (Vitest)<br>`npm run build` (Vite production build) |
| **`flutter`** | `ubuntu-latest` + Flutter stable + Java 17 | Flutter Client (`flutter_client/`) | `flutter pub get`<br>`flutter analyze`<br>`flutter test` (417 offline unit, widget, contract & intro tests) |
| **`security`** | `ubuntu-latest` | Full Repository | Gitleaks secret scanner (`gitleaks/gitleaks-action`) scanning for leaked API keys, tokens, credentials, and PII |

### Triggers & Concurrency
- **Triggers**: Pushes to `main`, pull requests targeting `main`, pushes to `android/antigravity-work`, and manual triggers (`workflow_dispatch`).
- **Concurrency**: Grouped by workflow and branch (`${{ github.workflow }}-${{ github.ref }}`). Outdated runs on pull request branches are automatically canceled (`cancel-in-progress: true`), while runs on `main` run to completion sequentially.
- **Permissions**: Read-only repository access (`contents: read`).

---

## 2. Test Isolation & Database Safety (Mandatory Invariant)

> [!CAUTION]
> **Production Database Protection:** Automated tests must **NEVER** connect to or interact with the production database (`media_server`).

### How CI Enforces Isolation
1. **Disposable PostgreSQL Service Container**: In CI, GitHub Actions spins up an ephemeral PostgreSQL 17 container on port 5432.
2. **Explicit Environment Overrides**:
   ```bash
   MEDIA_SERVER_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/media_server_test
   MEDIA_SERVER_TEST_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/media_server_test
   DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/media_server_test
   ```
   Setting both `MEDIA_SERVER_TEST_DATABASE_URL` and `MEDIA_SERVER_DATABASE_URL` ensures that even if code inadvertently invokes `AppConfig::from_env()`, it is trapped within the disposable test database.
3. **Synthetic Test Media Fixture**:
   Rather than requiring access to private media files or host storage (`D:\Flicks`), the CI backend job generates a lightweight 1-second synthetic video fixture using FFmpeg:
   ```bash
   mkdir -p /tmp/ms_test_fixtures/media /tmp/ms_cache
   ffmpeg -f lavfi -i testsrc=duration=1:size=320x240:rate=30 \
          -f lavfi -i sine=frequency=1000:duration=1 \
          -c:v libx264 -c:a aac -shortest /tmp/ms_test_fixtures/media/sample_test_movie.mp4
   ```
   This satisfies metadata discovery contracts (`test_support::seed_real_media_row()`) without leaking or requiring private libraries.
4. **Isolated Cache**:
   `MEDIA_SERVER_CACHE_DIR` points to an ephemeral directory (`/tmp/ms_cache`), ensuring tests never read or write to production HLS or preview thumbnail caches.

---

## 3. Local Verification Commands

Developers should reproduce the CI checks locally before committing or opening a pull request.

### 3.1 Rust Backend Checks (`rust/`)

```bash
cd rust

# 1. Format check
cargo fmt --check

# 2. Static analysis and lints
cargo clippy --all-targets -- -D warnings

# 3. Unit and integration tests
# Requires local PostgreSQL with test database (media_server_test)
cargo test --no-fail-fast -- --test-threads=1
```

*Note on Windows:* On Windows development environments where MSVC paths are configured via wrapper, developers can run:
```powershell
cmd /c "e:\MediaServer\scripts\cargo.bat test --no-fail-fast -- --test-threads=1"
```

### 3.2 React Frontend Checks (`web/`)

```bash
cd web

# 1. Clean install
npm ci

# 2. TypeScript type check
npm run typecheck

# 3. Linter
npm run lint

# 4. Vitest unit tests
npm run test

# 5. Production build
npm run build

# Alternatively, run all verification checks at once:
npm run verify
```

### 3.3 Flutter Client Checks (`flutter_client/`)

```bash
cd flutter_client

# 1. Fetch dependencies
flutter pub get

# 2. Static analysis and linter rules
flutter analyze

# 3. Unit, widget, and architecture contract tests
# Runs 417 offline unit, widget, and intro sequence tests.
# The 12 live-server integration tests automatically skip when MEDIA_SERVER_LIVE_TESTS is unset.
flutter test
```

---

## 4. Hardware-Dependent & Live Staging Probes

Some features require physical hardware or a running staging server and are **deliberately excluded from standard GitHub-hosted CI**:

1. **Dynamic Multi-GPU Chunked Transcoding:**
   - Transcoding using AMD AMF (`dx11:1` Radeon RX 560X and `dx11:0` Radeon Vega 8) requires physical AMD GPUs and DirectX 11 drivers present only on the Windows host.
   - Tested manually on host via active playback verification.
2. **LAN Cast & DLNA Discovery:**
   - Probing multicast SSDP or Cast devices requires access to the local home subnet.
3. **Live Client Contract Probes:**
   - [`scripts/probe_android_api.py`](../scripts/probe_android_api.py): Probes 22 endpoints against a running server (`http://127.0.0.1:8000`) populated with catalog movies.
   - [`scripts/probe_phase_8_contracts.py`](../scripts/probe_phase_8_contracts.py): Asserts quality ladder and transcode gating against a live server with MKV media.
   - Run these against local development or staging servers before production releases:
     ```bash
     python scripts/probe_android_api.py --base http://127.0.0.1:8000
     python scripts/probe_phase_8_contracts.py --base http://127.0.0.1:8000
     ```

---

## 5. Active Branch Protection Configuration (Enforced on `main`)

Branch protection is active on the `main` branch via GitHub repository policy:

1. **Required Status Checks (all 4 must pass before merging Pull Requests)**:
   - `Rust Backend (Axum)`
   - `React 19 Frontend (SPA)`
   - `Flutter Client (Android / TV)`
   - `Secrets & Security Scan`
2. **Strict Up-To-Date Requirement (`strict: true`)**: Branches must be up to date with `main` before merging.
3. **Repository Secret Scanning & Push Protection**: Native GitHub push protection actively scans every `git push` for known credentials (tokens, private keys, cloud secrets) and rejects pushes before they reach the repository.
4. **Admin Flexibility (`enforce_admins: false`, `required_pull_request_reviews: null`)**: Allows the sole maintainer to merge PRs without external approval gates and retains admin hotfix capabilities.
5. **Implementation Plans & Tracking**: [`docs/PLAN_BRANCH_PROTECTION.md`](PLAN_BRANCH_PROTECTION.md) and [`docs/PLAN_SECRETS_AND_PII_SCANNING.md`](PLAN_SECRETS_AND_PII_SCANNING.md).
