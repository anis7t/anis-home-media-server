# Implementation Plan: Production-Quality CI/CD Foundations for MediaServer

**Target Repository:** `anis7t/anis-home-media-server`  
**Default Branch:** `main`  
**Current Branch:** `android/antigravity-work`  
**Author:** Antigravity  
**Date:** 2026-10-29  

---

## 1. Executive Summary & Objective

Establish a robust, production-quality GitHub Actions Continuous Integration (CI) pipeline for **Anis' Home Media Server** to validate both the native **Rust / Axum backend** (`rust/`) and the **React 19 / TypeScript SPA frontend** (`web/`) on every push to `main` and pull request targeting `main`.

The pipeline enforces code formatting, static analysis/linting, compilation, automated unit/integration tests against an isolated ephemeral PostgreSQL container, and production frontend bundling—with strict zero-trust isolation from production databases, credentials, and local hardware.

---

## 2. Scope

### In Scope
1. **GitHub Actions Workflow (`.github/workflows/ci.yml`)**:
   - Pushes to `main`, PRs targeting `main`, and manual `workflow_dispatch`.
   - Least-privilege permissions (`contents: read`).
   - Concurrency management cancelling stale runs on PRs while preserving serialized runs on `main`.
   - Pinned immutable action commit SHAs with version comments.
   - **Backend Job (`backend`)**:
     - Ubuntu-latest runner with ephemeral PostgreSQL 17 service container.
     - System package dependencies (`pkg-config`, `libssl-dev`, `ffmpeg`).
     - Rust toolchain setup (stable) with `rustfmt` and `clippy`.
     - Cargo dependency caching keyed on `rust/Cargo.lock`.
     - Formatting check (`cargo fmt --check`).
     - Clippy static analysis (`cargo clippy --all-targets -- -D warnings`).
     - Synthetic test fixture generation (1s test video) for metadata probing contracts.
     - Automated test execution: `cargo test --no-fail-fast -- --test-threads=1`.
   - **Frontend Job (`frontend`)**:
     - Ubuntu-latest runner with Node.js 22 LTS.
     - Dependency caching and clean install via `npm ci` using `web/package-lock.json`.
     - TypeScript typecheck (`npm run typecheck`).
     - Linting with oxlint (`npm run lint`).
     - Automated Vitest unit test suite (`npm run test`).
     - Production Vite bundle build (`npm run build`).
2. **Production Database & Secret Protection**:
   - Explicit CI environment variables directing all database connections to `media_server_test` on `127.0.0.1:5432`.
   - Zero production credentials, tokens, or paths in workflow definitions.
   - Ephemeral cache and media directories located within runner temporary storage.
3. **Status Badge in `README.md`**:
   - Real GitHub Actions status badge pointing to `ci.yml` on branch `main`:  
     `https://github.com/anis7t/anis-home-media-server/actions/workflows/ci.yml/badge.svg?branch=main`.
4. **Testing Documentation (`docs/TESTING.md`)**:
   - Comprehensive guide on pipeline structure, trigger policies, local command equivalents, troubleshooting, and clear distinction between CI automation vs. live hardware/host probes (`scripts/probe_android_api.py`, `scripts/probe_phase_8_contracts.py`).
5. **Project Status Tracking**:
   - Documenting CI/CD foundations completion in `docs/PROJECT_STATUS.md`.

### Out of Scope (Deliberately Excluded)
- Modifying backend Axum architecture or React 19 frontend features.
- Running live GPU-dependent transcoding tests (AMD Radeon RX 560X / Vega 8 AMF requires dedicated Windows hardware).
- Running live LAN DLNA / Cast SSDP network discovery probes (requires physical LAN broadcast).
- Running Playwright E2E browser tests in default CI (E2E requires a running Axum backend on :8000 with real media files; retained for separate staging/nightly verification).
- Running `probe_android_api.py` and `probe_phase_8_contracts.py` in PR CI without a live media library instance.

---

## 3. Workflow Design & Invariants (`.github/workflows/ci.yml`)

### 3.1 Permissions & Triggers
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
```

### 3.2 Backend Job Design (`backend`)
- **Runner**: `ubuntu-latest`
- **Timeout**: 20 minutes
- **Services**:
  ```yaml
  services:
    postgres:
      image: postgres:17-alpine
      env:
        POSTGRES_USER: postgres
        POSTGRES_PASSWORD: postgres
        POSTGRES_DB: postgres
      ports:
        - 5432:5432
      options: >-
        --health-cmd pg_isready
        --health-interval 5s
        --health-timeout 5s
        --health-retries 5
  ```
- **Environment Invariants**:
  ```yaml
  env:
    CARGO_TERM_COLOR: always
    RUST_BACKTRACE: 1
    RUST_TEST_THREADS: 1
    MEDIA_SERVER_DATABASE_URL: postgresql://postgres:postgres@127.0.0.1:5432/media_server_test
    MEDIA_SERVER_TEST_DATABASE_URL: postgresql://postgres:postgres@127.0.0.1:5432/media_server_test
    DATABASE_URL: postgresql://postgres:postgres@127.0.0.1:5432/media_server_test
    MEDIA_SERVER_MEDIA_ROOT: /tmp/ms_test_fixtures/media
    MEDIA_SERVER_MEDIA_ROOTS: /tmp/ms_test_fixtures/media
    MEDIA_SERVER_CACHE_DIR: /tmp/ms_cache
  ```
- **Execution Steps**:
  1. `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` (# v4.2.2)
  2. Install Linux packages: `sudo apt-get update && sudo apt-get install -y pkg-config libssl-dev ffmpeg`
  3. Install Rust toolchain: `dtolnay/rust-toolchain@master` with `components: rustfmt, clippy`
  4. Cargo Cache: `actions/cache@d4323d4df104b026a6aa633fdb11d772146be0bf` (# v4.2.2) keyed on `rust/Cargo.lock`
  5. Check formatting: `cargo fmt --check --manifest-path rust/Cargo.toml`
  6. Clippy linting: `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings`
  7. Prepare synthetic test media fixture:
     ```bash
     mkdir -p /tmp/ms_test_fixtures/media /tmp/ms_cache
     ffmpeg -f lavfi -i testsrc=duration=1:size=320x240:rate=30 \
            -f lavfi -i sine=frequency=1000:duration=1 \
            -c:v libx264 -c:a aac -shortest /tmp/ms_test_fixtures/media/sample_test_movie.mp4
     ```
  8. Execute Rust tests:
     ```bash
     cargo test --manifest-path rust/Cargo.toml --no-fail-fast -- --test-threads=1
     ```

### 3.3 Frontend Job Design (`frontend`)
- **Runner**: `ubuntu-latest`
- **Timeout**: 10 minutes
- **Working Directory**: `web`
- **Execution Steps**:
  1. `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` (# v4.2.2)
  2. Setup Node.js: `actions/setup-node@39370e3970a6d050c480ffad4ff0ed4d3fdee5a1` (# v4.1.0) with `node-version: 22` and `cache: npm`, `cache-dependency-path: web/package-lock.json`
  3. Clean dependency install: `npm ci`
  4. Typecheck: `npm run typecheck`
  5. Lint: `npm run lint`
  6. Unit tests: `npm run test`
  7. Production build: `npm run build`

---

## 4. Exit Criteria

1. `.github/workflows/ci.yml` is committed and valid according to GitHub Actions schema.
2. The workflow includes both independent, concurrent `backend` and `frontend` jobs.
3. Actions use immutable commit SHAs with semantic version tags.
4. Database tests are strictly configured against disposable PostgreSQL test containers; production paths or URLs are impossible to reach.
5. `README.md` includes the official GitHub Actions workflow status badge targeting `ci.yml` on `main`.
6. `docs/TESTING.md` is created/updated documenting CI architecture, local reproduction steps, and platform-specific exclusions.
7. Local verification of syntax, diff integrity, and documentation matches all user guardrails.

---

## 5. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Accidental Production Database Access** | Potential catalog corruption or test failure in production. | Invariant enforced: explicit CI env vars override `MEDIA_SERVER_DATABASE_URL` and `MEDIA_SERVER_TEST_DATABASE_URL` to point strictly to container `127.0.0.1:5432/media_server_test`. No host secrets or `.env` files exposed. |
| **Missing Media Fixture in CI** | `api_contracts_test` or `media_info_test` panics when calling `discover_real_media_file`. | Invariant enforced: CI creates a valid 1s synthetic MP4 via `ffmpeg` in `/tmp/ms_test_fixtures/media/` before running tests. |
| **Clippy Platform Discrepancies** | Compiler lints differ between Windows and Linux. | Invariant enforced: Clean clippy run across all targets; address any legitimate cross-platform lint warnings safely without broad suppresses. |
| **Stale PR Builds Consuming Resources** | Excessive runner minutes spent on superseded PR commits. | Invariant enforced: Concurrency group cancels in-progress runs for the same branch or PR while preserving serialized runs on `main`. |

---

## 6. Open Decisions for User Approval

- **Action Pinning Format**: Pinned commit SHAs with inline version comments (`actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2`).
- **PostgreSQL Version**: `postgres:17-alpine` container selected for fast container pull and high compatibility with SQLx 0.8 / PostgreSQL 18.
- **Node.js Version**: Node 22 LTS for building React 19 frontend.