# Walkthrough: CI Integration & Renewed Commit/Push Rules in AGENTS.md & GEMINI.md

**Project:** Anis' Home Media Server  
**Date:** 2026-10-29  
**Status:** ✅ Complete & Verified  
**Implementation Plan:** [`docs/PLAN_CI_RULES_UPDATE.md`](PLAN_CI_RULES_UPDATE.md)

---

## 1. Executive Summary

In accordance with your directive, we updated [`AGENTS.md`](../AGENTS.md) and [`GEMINI.md`](../GEMINI.md) to integrate the full 4-pillar Continuous Integration architecture, establish repository push protection protocols, enforce branch protection status checks, and renew conflicting commit and push guidelines.

Critically, we incorporated a **two-tier local testing protocol** giving you and future agents the flexibility to choose between:
- **Tier 1 (Fast-Path Verification):** Rapid targeted checks for everyday development.
- **Tier 2 (Exhaustive Local Parity Suite):** Complete local execution mirroring GitHub Actions cloud runners for deep troubleshooting when diagnosing CI failures before pushing.

---

## 2. Detailed Deliverables & Changes

### 2.1 `GEMINI.md` Renewals
1. **Section 6 Renewed (`## 6. Git Operations, Commit Protocols & Push Protection`):**
   - **Automated Push Execution:** Clarified that automated `git push` is fully supported and permitted when repository credentials are configured non-interactively (e.g. system Git credential helper, SSH agent, or GitHub CLI token). Maintained strict guardrail against commands that stall on interactive terminal password prompts.
   - **Secret Scanning & Push Protection Guardrail:** Documented that GitHub native Secret Scanning and Push Protection actively inspect pushes at the Git wire boundary and block any commit containing credentials or tokens. Forbade bypassing push protection.
   - **Branch Protection & Status Check Invariant:** Documented the 4 required checks (`Rust Backend (Axum)`, `React 19 Frontend (SPA)`, `Flutter Client (Android / TV)`, `Secrets & Security Scan`) and `strict: true` up-to-date branch requirements on `main`.
   - **Dual-Tier Pre-Commit / Pre-Push Protocol:** Explicitly documented both the Fast-Path commands and the Exhaustive Local Parity Suite.
2. **New Section 30 Added (`## 30. Continuous Integration (GitHub Actions) & Security Scanning Invariants`):**
   - Documented the 4-pillar architecture in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).
   - Documented CI ephemeral PostgreSQL 17 test database isolation.
   - Documented headless Flutter requirements (`libmpv` initialization and deterministic asset list sorting).
   - Documented Gitleaks configuration ([`.gitleaks.toml`](../.gitleaks.toml)) allowlist maintenance.
   - Mandated exact string parity between branch protection context strings and CI job `name:` fields.
   - Linked canonical testing guide [`docs/TESTING.md`](TESTING.md).

### 2.2 `AGENTS.md` Renewals
1. **Section 1 (`## 1. Project identity and source of truth`):**
   - Added bullet point documenting the 4-pillar CI pipeline, branch protection enforcement, native secret scanning, and canonical guide [`docs/TESTING.md`](TESTING.md).
2. **Section 7 (`## 7. Testing protocol`):**
   - Replaced legacy single-block pre-commit commands with the **Dual-Tier Pre-Commit / Pre-Push Testing Protocol**:
     - *Tier 1 (Fast-Path)*: `cargo test`, `npm run test`, `npm run typecheck`, `flutter analyze`.
     - *Tier 2 (Exhaustive Local Parity Suite)*: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, `npm run typecheck`, `npm run lint`, `npm run test`, `npm run build`, `flutter analyze`, `.\scripts\run_flutter_tests.ps1`, `gitleaks git --pre-commit`, and live client contract probes.
3. **New Section 10 Added (`## 10. Continuous Integration, Branch Protection & Repository Security Guardrails`):**
   - Codified standing instructions for the 4 CI pillars, branch protection requirements, repository push protection, and non-interactive Git workflows.

---

## 3. Verification

1. **Document Validation:**
   - Both [`AGENTS.md`](../AGENTS.md) and [`GEMINI.md`](../GEMINI.md) were inspected for section numbering consistency and correct cross-linking.
   - Verified that all link anchors and relative paths (`docs/TESTING.md`, `.github/workflows/ci.yml`, `.gitleaks.toml`) resolve accurately.
2. **Git Working Tree Status:**
   - Changes ready for staging and commit to `main`.
