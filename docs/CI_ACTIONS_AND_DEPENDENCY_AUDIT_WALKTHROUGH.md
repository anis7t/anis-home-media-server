# Walkthrough: GitHub Actions Node 24 Runner Upgrade & Dependabot Security Remediation

## Executive Overview
Both operational issues flagged by GitHub on the `anis7t/anis-home-media-server` repository have been completely resolved, verified locally and in CI, committed to `main` (`ff58394`), and pushed to GitHub:
1. **GitHub Actions Node.js 20 Deprecation Warning**: Eliminated runner warning across all CI jobs by upgrading pinned actions to official major releases targeting Node 24 natively.
2. **Dependabot Vulnerability Alerts (5 Open Advisories: 4 High, 1 Moderate)**: Fully remediated by upgrading transitive development dependency `undici` from `7.30.0` to `7.30.2` in `web/package-lock.json`. All 5 alerts are officially marked `fixed` on GitHub.

---

## 1. Deliverables & Changes

### A. GitHub Actions Workflow Modernization ([`.github/workflows/ci.yml`](file:///e:/MediaServer/.github/workflows/ci.yml))
Updated all action SHA references to official releases running natively on Node 24:
- `actions/checkout`: Upgraded to `v7.0.1` (`3d3c42e5aac5ba805825da76410c181273ba90b1`) across `backend`, `frontend`, `flutter`, and `security` jobs.
- `actions/cache`: Upgraded to `v6.1.0` (`55cc8345863c7cc4c66a329aec7e433d2d1c52a9`) in `backend` job.
- `actions/setup-node`: Upgraded to `v7.1.0` (`949feb2413d6458794dcd2491c4babbbce0c15c1`) in `frontend` job.
- `actions/setup-java`: Upgraded to `v6.3.0` (`d1374f8ac74474200d16ef8ecee22c7ae7a51880`) in `flutter` job.
- `subosito/flutter-action`: Comment tag updated to `# v2.23.0` (composite action).

### B. Dependabot Security Remediation ([`web/package-lock.json`](file:///e:/MediaServer/web/package-lock.json))
Executed `npm audit fix` in `web/` to patch `undici` from `7.30.0` to `7.30.2`:
- **Advisories Patched**:
  1. `GHSA-4w7w-5xrc-9h26` / `CVE-2026-109829` (High — cache poisoning and cross-user disclosure via cross-origin redirects).
  2. `GHSA-2m5v-pch6-74hx` (High — TLS certificate validation bypass via dropped TLS options in Agent).
  3. `GHSA-qrxm-fqhp-jwvm` / `CVE-2026-87018` (High — DoS via TLS 1.2 certificate-changing renegotiation).
  4. `GHSA-xjj6-f33q-929c` (High — DoS via unhandled error on excessive content-encodings).
  5. `GHSA-9fm3-97px-rjf6` (Moderate — WebSocket client DoS via unbounded automatic PONG buffering).
- **Result**: `npm audit` reports `found 0 vulnerabilities`.
- **Dependabot PR #12**: Automatically closed and merged by GitHub upon receiving the lockfile update on `main`.

### C. Test Harness Stability ([`rust/tests/integration/media_pipeline/hls_transcode_test.rs`](file:///e:/MediaServer/rust/tests/integration/media_pipeline/hls_transcode_test.rs))
- Replaced non-deterministic `hls_candidates.into_iter().next().unwrap()` in `test_hls_playlist_query_start_slices` with canonical `HlsService::find_hls_dir()`.
- Prevents randomized `HashSet` candidate order from picking a non-primary key during test execution, ensuring 100% deterministic test execution.

### D. Documentation & Traceability
- [`docs/PROJECT_STATUS.md`](file:///e:/MediaServer/docs/PROJECT_STATUS.md): Stamped with the 2026-11-23 entry.
- [`docs/CI_ACTIONS_AND_DEPENDENCY_AUDIT_PLAN.md`](file:///e:/MediaServer/docs/CI_ACTIONS_AND_DEPENDENCY_AUDIT_PLAN.md): Implementation plan archived.
- [`Handoffs/2026-11-23_02-18_gemini.md`](file:///e:/MediaServer/Handoffs/2026-11-23_02-18_gemini.md): Session handoff recorded.

---

## 2. Verification Outcomes

### Local Verification
| Pillar / Component | Command | Result |
| :--- | :--- | :--- |
| **Frontend Security Audit** | `npm --prefix web audit` | `found 0 vulnerabilities` |
| **Frontend Typecheck** | `npm --prefix web run typecheck` | Passed (code 0) |
| **Frontend Lint** | `npm --prefix web run lint` | Passed (0 errors) |
| **Frontend Unit Tests** | `npm --prefix web run test` | 46 test files / 340 tests passed |
| **Frontend Build** | `npm --prefix web run build` | Passed (production Vite bundle) |
| **Flutter Static Analysis** | `flutter analyze` | `No issues found!` |
| **Rust Formatting** | `cargo fmt --check` | Passed (code 0) |
| **Rust Clippy** | `cargo clippy --all-targets -- -D warnings` | Passed (0 warnings) |
| **Rust HLS Suite** | `cargo test media_pipeline::hls_transcode_test` | 16/16 tests passed |

### GitHub Actions CI Verification (Run `45068446759` on `main`)
| CI Job | Status | Duration | Node.js 20 Deprecation Warning |
| :--- | :--- | :--- | :--- |
| **Rust Backend (Axum)** | `completed / success` | 2m 20s | **None** (Clean `[]`) |
| **Flutter Client (Android / TV)** | `completed / success` | 3m 35s | **None** (Clean `[]`) |
| **React 19 Frontend (SPA)** | `completed / success` | 57s | **None** (Clean `[]`) |
| **Secrets & Security Scan** | `completed / success` | 14s | **None** (Clean `[]`) |

### GitHub Dependabot Security Alert Status
Querying `repos/anis7t/anis-home-media-server/dependabot/alerts`:
- Alert #10 (`undici` High): **`fixed`**
- Alert #9 (`undici` High): **`fixed`**
- Alert #8 (`undici` High): **`fixed`**
- Alert #7 (`undici` Moderate): **`fixed`**
- Alert #5 (`undici` High): **`fixed`**
- **Total Open Vulnerabilities Remaining: 0**
