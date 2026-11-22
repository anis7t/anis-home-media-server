# Implementation Plan: GitHub Actions Node 24 Upgrade & Dependabot Security Remediation

## Executive Summary
This implementation plan addresses two operational issues flagged by GitHub on the `anis7t/anis-home-media-server` repository:
1. **GitHub Actions Runner Deprecation Warning:** Runners are sunsetting Node.js 20 and forcing workflow actions targeting Node 20 to run on Node.js 24 (`actions/checkout`, `actions/cache`, `actions/setup-node`, `actions/setup-java`).
2. **Dependabot Vulnerability Alerts (5 Open Alerts: 4 High, 1 Moderate):** Dependabot reported security advisories in `web/package-lock.json` regarding transitive development dependency `undici` (versions `7.0.0`–`7.30.0`), patched in `7.30.2`.

---

## 1. Scope
### What Changes:
- **CI Workflow Configuration (`.github/workflows/ci.yml`):**
  - Upgrade `actions/checkout` from `v4.2.2` (`11bd71901bbe5b1630ceea73d27597364c9af683`) to `v7.0.1` (`3d3c42e5aac5ba805825da76410c181273ba90b1`), targeting `node24` natively across all 4 CI jobs (`backend`, `frontend`, `flutter`, `security`).
  - Upgrade `actions/cache` in `backend` job from `v4.2.2` (`d4323d4df104b026a6aa633fdb11d772146be0bf`) to `v6.1.0` (`55cc8345863c7cc4c66a329aec7e433d2d1c52a9`), targeting `node24` natively.
  - Upgrade `actions/setup-node` in `frontend` job from `v4.1.0` (`39370e3970a6d050c480ffad4ff0ed4d3fdee5af`) to `v7.1.0` (`949feb2413d6458794dcd2491c4babbbce0c15c1`), targeting `node24` natively.
  - Upgrade `actions/setup-java` in `flutter` job from `@v5` to `v6.3.0` (`d1374f8ac74474200d16ef8ecee22c7ae7a51880`), targeting `node24` natively.
- **Frontend Dependencies (`web/package-lock.json`):**
  - Execute `npm audit fix` in `web/` to bump `undici` from `7.30.0` to `7.30.2` (resolving advisories `GHSA-4w7w-5xrc-9h26`, `GHSA-2m5v-pch6-74hx`, `GHSA-qrxm-fqhp-jwvm`, `GHSA-xjj6-f33q-929c`, `GHSA-9fm3-97px-rjf6`).
  - Close or supersede open Dependabot Pull Request #12 upon merging lockfile update to `main`.
- **Project Documentation (`docs/PROJECT_STATUS.md` & Session Handoff):**
  - Document the resolved CI runner deprecation and security advisory closure.

### What Deliberately Does NOT Change:
- Zero changes to production application code in Rust (`rust/`), React runtime components (`web/src/`), or Flutter client (`flutter_client/`).
- Zero changes to database schemas, APIs, or deployed Windows services (`MediaServerRust`, `MediaServerPG`, `MediaServerCaddy`).
- `gitleaks-action` and `flutter-action` configurations remain structurally preserved as they already target Node 24 or run as composite actions.

---

## 2. Step-by-Step Execution Plan

### Step 1: Remediate `web/package-lock.json`
1. Run `npm --prefix web audit fix` locally.
2. Confirm `web/package-lock.json` specifies `undici: 7.30.2`.
3. Run `npm --prefix web audit` to verify 0 vulnerabilities remain.
4. Execute full frontend verification suite:
   ```powershell
   npm --prefix web run typecheck
   npm --prefix web run lint
   npm --prefix web run test
   npm --prefix web run build
   ```

### Step 2: Update CI Workflow Actions (`.github/workflows/ci.yml`)
1. Update action SHA references and version comments:
   - `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` (lines 56, 135, 170, 207)
   - `actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0` (line 70)
   - `actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0` (line 138)
   - `actions/setup-java@d1374f8ac74474200d16ef8ecee22c7ae7a51880 # v6.3.0` (line 173)
2. Validate YAML syntax and action options integrity.

### Step 3: Run Local Tier-1 Verification Suite
1. Run Rust test suite:
   ```powershell
   cargo test --manifest-path rust/Cargo.toml -- --test-threads=1
   ```
2. Run Flutter static analysis:
   ```powershell
   cd flutter_client; flutter analyze; cd ..
   ```
3. Run React frontend verification:
   ```powershell
   npm --prefix web run test
   npm --prefix web run typecheck
   ```

### Step 4: Documentation, Commit & Remote Push
1. Update `docs/PROJECT_STATUS.md` and create session handoff in `Handoffs/`.
2. Stage and commit changes to `main`:
   ```bash
   git add .github/workflows/ci.yml web/package-lock.json docs/PROJECT_STATUS.md Handoffs/
   git commit -m "ci: upgrade actions to node 24 and patch undici security advisories"
   ```
3. Push to `origin main`.

### Step 5: Post-Push Verification
1. Monitor GitHub Actions CI run on `main`:
   ```powershell
   gh run watch
   ```
2. Verify all 4 jobs pass 100% green without any Node.js 20 deprecation annotations.
3. Query GitHub Dependabot alerts API to verify all 5 alerts are marked `resolved` / `closed`.
4. Close open Dependabot PR #12 (if not auto-closed by GitHub).

---

## 3. Exit Criteria
- [ ] `npm --prefix web audit` outputs `found 0 vulnerabilities`.
- [ ] `.github/workflows/ci.yml` pins all actions to Node 24 native releases.
- [ ] Local verification commands (`cargo test`, `npm run test`, `npm run typecheck`, `flutter analyze`) pass with 0 errors.
- [ ] GitHub Actions CI run on `main` passes across all 4 pillars (`Rust Backend`, `React 19 Frontend`, `Flutter Client`, `Secrets & Security Scan`) with **zero** Node.js 20 deprecation warnings.
- [ ] All 5 Dependabot security alerts on `anis7t/anis-home-media-server` are closed.

---

## 4. Risks & Mitigations
| Risk | Potential Impact | Mitigation |
| :--- | :--- | :--- |
| **Action API incompatibility** in newer major versions (`actions/checkout@v7`, `actions/cache@v6`, `actions/setup-node@v7`) | Workflow job fails during execution on runner | Verified that input schemas (`path`, `key`, `restore-keys`, `node-version`, `cache`) remain backward-compatible; monitored via CI run |
| **`npm audit fix` unintended lockfile churn** | Changes unrelated packages or breaks dev build | Dry-run confirmed only `undici` changes from `7.30.0` to `7.30.2`; full build & test suite run locally before pushing |
| **Branch protection rejection** | Push blocked if checks fail | Local parity verification run prior to commit; push to `main` followed by real-time CI monitoring |

---

## 5. Open Decisions
- None. Both upgrades follow standard official security releases and runner platform migrations.
