# Implementation Plan: Secrets, Tokens & PII Security Scanning

## Context & Objectives
While the repository now enforces a 3-pillar CI pipeline (Rust backend, React frontend, Flutter client) and branch protection on `main`, the current CI workflow and repository settings do not scan for leaked secrets, API tokens, private keys, or unintentional PII.

A query to the repository settings API reveals:
- `"secret_scanning": {"status": "disabled"}`
- `"secret_scanning_push_protection": {"status": "disabled"}`

This plan establishes a two-layer defense against credential leaks and PII exposure:
1. **Repository-Level Protection:** Enable GitHub's native **Secret Scanning** and **Secret Scanning Push Protection** via GitHub API.
2. **CI Pipeline Gatekeeper:** Add a dedicated, concurrent **Secrets & Security Scan** job (`gitleaks-action`) to `.github/workflows/ci.yml`, backed by a project `.gitleaks.toml` configuration that allows test fixtures while detecting real credentials.
3. **Branch Protection Enforcement:** Add `Secrets & Security Scan` to the required status checks enforced on `main`.

---

## Proposed Architecture

```text
Developer / Agent (git push)
  │
  ▼
[Layer 1: GitHub Push Protection] ────> BLOCKS push if known secret/token detected (AWS, GitHub, GCP, Stripe, etc.)
  │ (Permitted push)
  ▼
[GitHub Actions CI Pipeline]
  ├─ Rust Backend (Axum)
  ├─ React 19 Frontend (SPA)
  ├─ Flutter Client (Android / TV)
  └─ [Layer 2: Secrets & Security Scan (Gitleaks)] ────> Scans full commit diff for high-entropy tokens, passwords, keys
        │
        ▼
[Branch Protection on `main`] ────> All 4 checks must be 100% green before any PR can merge
```

---

## Scope

### In Scope:
1. **Enable GitHub Native Secret Scanning & Push Protection:**
   - Call GitHub REST API `PATCH /repos/anis7t/anis-home-media-server` to enable `secret_scanning` and `secret_scanning_push_protection`.
2. **Create Project `.gitleaks.toml`:**
   - Define baseline secret patterns and configure allowlists for test fixtures (e.g. synthetic test hashes, mock UUIDs).
3. **Add `security` Job to [`.github/workflows/ci.yml`](../.github/workflows/ci.yml):**
   - Run `gitleaks/gitleaks-action` with pinned commit SHA on Ubuntu runner.
4. **Update Branch Protection on `main`:**
   - Update `required_status_checks.contexts` to include `Secrets & Security Scan`.
5. **Documentation & Verification:**
   - Update [`docs/TESTING.md`](TESTING.md) and [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md).
   - Verify green CI run on `main`.
   - Publish walkthrough in [`docs/WALKTHROUGH_SECRETS_SCANNING.md`](WALKTHROUGH_SECRETS_SCANNING.md).

### Out of Scope:
- Scanning binary movie media files (`.mp4`, `.mkv`) in test media fixtures.
- Introducing paid commercial SAST tooling (Gitleaks is open-source and free).

---

## Exit Criteria

1. `gh api repos/anis7t/anis-home-media-server --jq ".security_and_analysis"` returns:
   - `secret_scanning.status == "enabled"`
   - `secret_scanning_push_protection.status == "enabled"`
2. CI pipeline executes `Secrets & Security Scan` concurrently with backend, frontend, and flutter jobs and passes.
3. Branch protection on `main` requires all 4 checks:
   - `Rust Backend (Axum)`
   - `React 19 Frontend (SPA)`
   - `Flutter Client (Android / TV)`
   - `Secrets & Security Scan`
4. Working directory clean and verified.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Gitleaks flags synthetic test hashes as secrets | Medium | Configure `.gitleaks.toml` with path and regex allowlists for test directories and mock fixtures. |
| Checkout depth insufficient for commit analysis | Low | Use `fetch-depth: 0` in the security job step so git commit history is readable by Gitleaks. |
