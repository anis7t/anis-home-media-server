# Implementation Plan: Document, Commit, and Open PR for Dual-GPU Diagnostic Logging

## 1. Overview & Goal
Document the newly completed and deployed Dual-GPU concurrent transcoding activation and persistent FFmpeg stderr diagnostic logging, create the session handoff, push the feature branch `feat/dual-gpu-diagnostics` to GitHub, and open a Pull Request targeting `main`.

---

## 2. Scope

### In Scope
1. **Documentation Updates**:
   - Update [`docs/PROJECT_STATUS.md`](file:///e:/MediaServer/docs/PROJECT_STATUS.md):
     - Record the persistent on-disk FFmpeg stderr capture implementation (`logs/gpu/`, 4 MiB file cap, 256 MiB total cap, crash retention).
     - Record structured thermal and AMF probe diagnostic telemetry.
     - Record production service activation of `MEDIA_SERVER_ENABLE_DUAL_GPU=1` and GPU debug logging in NSSM and `.env`.
     - Record deployment automation in `scripts/deploy_dual_gpu_service.ps1`.
   - Create Session Handoff Document:
     - [`Handoffs/2026-11-21_14-30_antigravity_dual-gpu-activation-and-diagnostic-logging.md`](file:///e:/MediaServer/Handoffs/2026-11-21_14-30_antigravity_dual-gpu-activation-and-diagnostic-logging.md).
2. **Verification & Clean Commit**:
   - Verify code formatting with `cargo fmt --manifest-path rust/Cargo.toml --check`.
   - Verify secret cleanliness (`git diff` inspection to guard against token leakage).
   - Commit the documentation updates to `feat/dual-gpu-diagnostics`.
3. **GitHub Push & Pull Request Creation**:
   - Push `feat/dual-gpu-diagnostics` to `origin`.
   - Open Pull Request to `main` using GitHub CLI (`gh pr create`).
   - Monitor the 4 required CI status checks (`Rust Backend (Axum)`, `React 19 Frontend (SPA)`, `Flutter Client (Android / TV)`, `Secrets & Security Scan`).

### Deliberately Out of Scope
- Altering production backend code (already compiled, verified, and running).
- Modifying frontend or mobile client packages.

---

## 3. Exit Criteria
- [ ] `docs/PROJECT_STATUS.md` and handoff document updated and committed.
- [ ] `feat/dual-gpu-diagnostics` successfully pushed to `origin`.
- [ ] GitHub Pull Request opened against `main` with summary and verification evidence.
- [ ] CI pipeline status reported to user.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation / Control |
| :--- | :--- | :--- |
| **Secret Scanning Push Rejection** | `git push` rejected at wire | Verify all `.env` changes stay untracked/ignored; ensure no API tokens or passwords in docs/scripts. |
| **CI Static Analysis Failure** | Branch protection blocks merge | Run `cargo fmt --check` locally before pushing to ensure zero style regressions. |

---

## 5. Open Decisions
1. **Pull Request Merge Timing**:
   - **(Recommended) Leave PR Open**: Keep PR open after CI checks pass, allowing user review before merging into `main`.
   - **Alternative**: Enable auto-merge (`gh pr merge --auto`).
