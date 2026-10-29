# Implementation Plan: Exhaustive Branch Protection Verification Probe

## Context & Objectives
Branch protection has been activated on `main` requiring three status checks (`Rust Backend (Axum)`, `React 19 Frontend (SPA)`, and `Flutter Client (Android / TV)`) and `strict: true`.
To exhaustively verify that GitHub actively enforces this policy on Pull Requests, we will execute an end-to-end verification probe using a temporary branch and Pull Request, inspect GitHub's merge gating in both blocked and clean states, and cleanly teardown the test artifacts.

---

## Scope

### In Scope:
1. **Test Branch Creation:** Create temporary branch `test/branch-protection-probe` off current `main`.
2. **Benign Probe Commit:** Commit a temporary verification marker (`docs/TEST_BRANCH_PROTECTION_MARKER.md`) and push to remote.
3. **Pull Request Creation:** Open a Pull Request targeting `main`.
4. **Gating State Verification (Phase 1 — Blocked):**
   - Inspect GitHub merge status while CI is pending or unfulfilled.
   - Assert `mergeStateStatus == "BLOCKED"` / `mergeable_state == "blocked"`.
5. **Passing State Verification (Phase 2 — Clean):**
   - Monitor CI run until all three jobs (`Rust Backend (Axum)`, `React 19 Frontend (SPA)`, `Flutter Client (Android / TV)`) complete.
   - Assert `mergeStateStatus == "CLEAN"` / `mergeable_state == "clean"`.
6. **Zero-Residue Cleanup:**
   - Close the Pull Request without merging (`gh pr close --delete-branch`).
   - Switch local branch back to `main` and delete the local test branch.
   - Document verification outcome in [`docs/WALKTHROUGH_BRANCH_PROTECTION_TEST.md`](WALKTHROUGH_BRANCH_PROTECTION_TEST.md).

### Out of Scope:
- Merging the probe commit into `main`.
- Modifying production code or CI workflows.

---

## Exit Criteria

1. Phase 1 proves GitHub reports `mergeable_state == "blocked"` on the PR before checks complete.
2. Phase 2 proves GitHub reports `mergeable_state == "clean"` once all 3 checks succeed.
3. Test PR is closed, remote branch is deleted, and local git status is cleanly back on `main`.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Test PR accidentally merged into `main` | Medium | The plan explicitly closes the PR via `gh pr close` without merging. |
| Lingering test branch or PR left open | Low | Step 6 explicitly executes teardown (`gh pr close --delete-branch`, `git branch -D`). |
| Runner minute usage | Low | The probe tests the real CI pipeline once; standard lightweight run (~4m). |
