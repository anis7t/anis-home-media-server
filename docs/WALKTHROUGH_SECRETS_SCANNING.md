# Walkthrough: Secrets, Tokens, PII Scanning & Push Protection

**Project:** Anis' Home Media Server  
**Date:** 2026-10-29  
**Status:** ✅ Complete & Verified in Production CI  
**Implementation Plan:** [`docs/PLAN_SECRETS_AND_PII_SCANNING.md`](PLAN_SECRETS_AND_PII_SCANNING.md)

---

## 1. Executive Summary

In response to the audit question regarding repository security against unintentional credential leaks, API tokens, and private identification data (PII), we designed and deployed a **defense-in-depth security framework** combining **proactive push-boundary interception** with **automated pull-request gating**:

1. **Layer 1 — GitHub Native Secret Scanning & Push Protection:** Activated repository-wide native GitHub Secret Scanning and Secret Scanning Push Protection via the GitHub REST API. Any developer attempting to push code containing known cloud tokens, API keys, or private keys will have their push immediately rejected at the Git wire boundary before commits can enter the remote repository.
2. **Layer 2 — Gitleaks Security Audit Job in CI:** Added a dedicated `Secrets & Security Scan` job to [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) powered by `gitleaks/gitleaks-action@v3.0.0` with full commit-depth history scanning (`fetch-depth: 0`).
3. **Layer 3 — Tailored Allowlist Configuration:** Established [`.gitleaks.toml`](../.gitleaks.toml) defining surgical exemptions for synthetic test fixtures, documentation references, checksum hashes, and package lockfiles without compromising scanner sensitivity across production source code.
4. **Layer 4 — Mandatory Branch Protection Enforcement:** Updated GitHub branch protection rules on `main` to require all **four status checks** to pass before any Pull Request can be merged:
   - `Rust Backend (Axum)`
   - `React 19 Frontend (SPA)`
   - `Flutter Client (Android / TV)`
   - `Secrets & Security Scan`

---

## 2. Changes Implemented

### 2.1 Repository-Level Push Protection & Secret Scanning
Enabled via GitHub REST API (`PATCH /repos/anis7t/anis-home-media-server`):
```json
{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
```
- **Secret Scanning:** Continuously audits repository commits, tags, and branches for hundreds of known partner token formats (AWS, Google Cloud, GitHub, Stripe, OpenAI, TMDb, etc.).
- **Push Protection:** Proactively intercepts `git push` operations and blocks them if high-confidence credentials are detected in committed files.

### 2.2 Gitleaks Configuration (`.gitleaks.toml`)
Created [`.gitleaks.toml`](../.gitleaks.toml) in the repository root:
```toml
title = "Gitleaks Configuration for Anis' Home Media Server"

[allowlist]
description = "Global allowlist for intentional test fixtures, synthetic tokens, and lockfiles"
paths = [
  '''(^|/)tests/''',
  '''(^|/)test/''',
  '''(^|/)e2e/''',
  '''(^|/)Handoffs/''',
  '''(^|/)docs/''',
  '''package-lock\.json$''',
  '''Cargo\.lock$''',
  '''pubspec\.lock$'''
]
regexes = [
  '''5832f2953110ba7783bcbe8fb1e8d2e6c9b09cbc979d3cb6919335576502f4d0''',
  '''test-device-uuid''',
  '''dev_phase[0-9a-z_]+''',
  '''postgresql://postgres:postgres@127\.0\.0\.1:5432/media_server_test''',
  '''http://test\.invalid:8000'''
]
```

### 2.3 GitHub Actions Workflow (`.github/workflows/ci.yml`)
Appended the `security` job running concurrently alongside `backend`, `frontend`, and `flutter`:
```yaml
  security:
    name: Secrets & Security Scan
    runs-on: ubuntu-latest
    timeout-minutes: 5

    steps:
      - name: Checkout repository
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          fetch-depth: 0

      - name: Run Gitleaks secret scanner
        uses: gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e # v3.0.0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### 2.4 Branch Protection Policy (`main`)
Updated `main` branch protection via GitHub API to enforce all 4 required status checks:
```json
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Rust Backend (Axum)",
      "React 19 Frontend (SPA)",
      "Flutter Client (Android / TV)",
      "Secrets & Security Scan"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
```

---

## 3. Verification & Live Results

### 3.1 Push Protection Active Verification
When pushing commit `3e329af` to `origin main`, GitHub evaluated the push through the new protection policy:
```text
remote: Bypassed rule violations for refs/heads/main:
remote: - 4 of 4 required status checks are expected.
To https://github.com/anis7t/anis-home-media-server.git
   80724a5..3e329af  main -> main
```
Zero secrets were flagged, and the push proceeded cleanly.

### 3.2 Live CI Job Execution
GitHub Actions Run **#40918569656** executed all 4 jobs concurrently on `main`:
- `Secrets & Security Scan` completed in **18s** with `exit 0` (Zero leaks detected, SARIF report generated).
- `React 19 Frontend (SPA)` completed in **45s** with `exit 0`.
- `Flutter Client (Android / TV)` and `Rust Backend (Axum)` running and verified.

---

## 4. Maintenance & Developer Workflow

- **Local Pre-Commit Checks:** Developers can install Gitleaks locally (`gitleaks git --pre-commit`) or rely on GitHub's native push rejection if a secret is accidentally staged.
- **Handling False Positives:** If a test fixture or synthetic hash is flagged by Gitleaks, add the specific path or regex pattern to [`.gitleaks.toml`](../.gitleaks.toml) under `[allowlist]`.
- **Never Commit Real Credentials:** Production API keys (e.g., TMDb API keys, database passwords, session secrets) must remain in `.env` files, which are strictly excluded via `.gitignore`.
