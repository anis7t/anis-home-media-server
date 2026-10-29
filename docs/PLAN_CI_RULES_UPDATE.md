# Implementation Plan: CI Integration & Renewed Commit/Push Rules in AGENTS.md & GEMINI.md

**Date:** 2026-10-29  
**Target Files:** [`AGENTS.md`](../AGENTS.md), [`GEMINI.md`](../GEMINI.md)  
**Context:** Update project guidelines to incorporate the 4-pillar CI pipeline, Gitleaks secrets scanning, repository push protection, branch protection requirements, and renew git commit/push guardrails.

---

## 1. Scope

### In Scope
1. **`GEMINI.md` Section 6 (Git Operations & Push Guardrail Renewal):**
   - Renew the "Non-Interactive Push Guardrail": Clarify that automated `git push` is fully permitted when authentication credentials are configured (e.g. system credential helper, SSH, or PAT), while commands that block on interactive terminal credential prompts remain guarded.
   - Add **Secret Scanning Push Protection Guardrail**: Document that native GitHub push protection actively blocks pushes containing credentials, tokens, or private keys. Forbid bypassing push protection or using `--no-verify` to bypass secret checks.
   - Add **Branch Protection & Status Check Invariant**: Document that `main` is protected by 4 required CI status checks (`Rust Backend (Axum)`, `React 19 Frontend (SPA)`, `Flutter Client (Android / TV)`, `Secrets & Security Scan`) and `strict: true` up-to-date branch requirements.
2. **`GEMINI.md` Section 30 (Continuous Integration & Security Scanning Invariants):**
   - Add dedicated section detailing the 4-pillar GitHub Actions pipeline (`.github/workflows/ci.yml`).
   - Document ephemeral CI database safety (PostgreSQL 17 service container) and synthetic media fixture generation.
   - Document headless Flutter test requirements (system `libmpv` installation and deterministic asset list sorting).
   - Document Gitleaks configuration (`.gitleaks.toml`) and test fixture allowlisting rules.
3. **`AGENTS.md` Section 1 (Project Identity & Source of Truth):**
   - Add CI pipeline documentation reference (`docs/TESTING.md`), status checks, and Gitleaks security scanning.
4. **`AGENTS.md` Section 7 (Testing Protocol & Pre-Commit Verification):**
   - Update pre-commit verification steps to include `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `npm run typecheck`, `npm run lint`, `flutter analyze`, and `flutter test`.
   - Document CI workflow trigger behavior and status check synchronization.
5. **`AGENTS.md` Section 10 (CI/CD, Branch Protection & Repository Security Guardrails):**
   - Add comprehensive guidelines covering branch protection, secret scanning, and automated CI gating.

### Deliberately Out of Scope
- Modifying production application code in `rust/`, `web/`, or `flutter_client/`.
- Changing GitHub Actions workflow files or `.gitleaks.toml` (already completed and verified in CI run #40918569656).
- Altering any other project rules or coding invariants.

---

## 2. Exit Criteria

- [ ] `GEMINI.md` Section 6 renewed: clarifies automated push etiquette vs blocking credential prompts, documents native Secret Scanning Push Protection, and details branch protection requirements.
- [ ] `GEMINI.md` Section 30 added: documents 4-pillar CI pipeline, ephemeral database isolation, Flutter headless requirements, and Gitleaks allowlist protocols.
- [ ] `AGENTS.md` Section 1, Section 7, and new Section 10 updated: reflects the 4 CI checks, pre-commit/pre-push verification suite, and repository security policies.
- [ ] All internal markdown links resolve correctly and adhere to repository link formatting rules.
- [ ] Changes committed and pushed to `main`, successfully evaluated through the 4-check CI pipeline and push protection.

---

## 3. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Ambiguity in push rules leading to blocked agent actions** | Agent could get confused about whether running `git push` is allowed or forbidden | State clearly that non-interactive authenticated pushes (`git push origin <branch>`) are permitted, while interactive credential prompts are forbidden. |
| **Desynchronization between rule names and GitHub check contexts** | Branch protection fails if status check names do not match job names exactly | Enforce exact string matching in documentation: `Rust Backend (Axum)`, `React 19 Frontend (SPA)`, `Flutter Client (Android / TV)`, `Secrets & Security Scan`. |
| **Breaking document formatting or numbering** | Inconsistent document structure in `GEMINI.md` or `AGENTS.md` | Follow sequential numbering (adding Section 30 in `GEMINI.md` and Section 10 in `AGENTS.md`) without disrupting existing sections. |

---

## 4. Open Decisions

1. **Pre-Commit vs Pre-Push Local Testing Scope:**
   - **Decision (User Approved):** Provide a **two-tier testing protocol** in both `AGENTS.md` and `GEMINI.md`:
     1. **Fast-Path Verification (Standard Iteration):** Rapid targeted checks (`cargo test`, `npm run test`, `npm run typecheck`, `flutter analyze`) for normal development.
     2. **Exhaustive Local CI Parity Suite (Deep Troubleshooting):** Full local suite mirroring GitHub Actions (`cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, `npm run typecheck`, `npm run lint`, `npm run test`, `npm run build`, `flutter analyze`, `.\scripts\run_flutter_tests.ps1`, and Gitleaks scan) to be selected when diagnosing CI failures or validating major cross-cutting changes before pushing.

