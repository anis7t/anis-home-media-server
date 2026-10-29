# Walkthrough: Exhaustive Branch Protection Verification Test

## Executive Summary

To exhaustively verify that GitHub actively enforces branch protection on `main`, an end-to-end verification probe was executed using a temporary branch (`test/branch-protection-probe`) and Pull Request [#14](https://github.com/anis7t/anis-home-media-server/pull/14).

The test conclusively demonstrated both operational states:
1. **Phase 1 (Gating While Checks Are Incomplete):**
   - When the PR was opened with checks in progress, GitHub's branch protection engine blocked the merge.
   - Even when `React 19 Frontend (SPA)` and `Rust Backend (Axum)` had already passed, the merge remained strictly blocked (`"mergeStateStatus": "BLOCKED"`, `"mergeable_state": "blocked"`) until the third check (`Flutter Client (Android / TV)`) finished.
2. **Phase 2 (Clean Transition Upon 3-Check Completion):**
   - As soon as all three CI jobs finished with success, GitHub automatically transitioned the PR to mergeable (`"mergeStateStatus": "CLEAN"`, `"mergeable_state": "clean"`).
3. **Phase 3 (Zero-Residue Teardown):**
   - The test PR was closed without merging (`gh pr close 14 --delete-branch`), deleting the remote test branch.
   - The local workspace was restored cleanly to `main` with zero leftover test artifacts.

---

## Technical Evidence Ledger

### Phase 1: Blocked State Inspection

#### Initial State (All Checks In Progress)
```json
{
  "number": 14,
  "mergeable": "MERGEABLE",
  "mergeStateStatus": "BLOCKED",
  "statusCheckRollup": [
    {"name": "Rust Backend (Axum)", "status": "IN_PROGRESS"},
    {"name": "React 19 Frontend (SPA)", "status": "IN_PROGRESS"},
    {"name": "Flutter Client (Android / TV)", "status": "IN_PROGRESS"}
  ]
}
```
REST API output:
```json
{"mergeable": true, "mergeable_state": "blocked"}
```

#### Intermediate State (2 of 3 Passed, 1 In Progress)
```json
{
  "mergeStateStatus": "BLOCKED",
  "statusCheckRollup": [
    {"name": "Rust Backend (Axum)", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"name": "React 19 Frontend (SPA)", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"name": "Flutter Client (Android / TV)", "status": "IN_PROGRESS"}
  ]
}
```
*Crucial finding:* Even with 2 out of 3 checks passing, GitHub kept the PR in `BLOCKED` status.

---

### Phase 2: Clean State Inspection (All 3 Passed)

Run [40916155029](https://github.com/anis7t/anis-home-media-server/actions/runs/40916155029):
- `✓ React 19 Frontend (SPA)` in 1m 1s
- `✓ Rust Backend (Axum)` in 2m 26s
- `✓ Flutter Client (Android / TV)` in 3m 29s

PR Status once all 3 checks completed:
```json
{
  "number": 14,
  "mergeable": "MERGEABLE",
  "mergeStateStatus": "CLEAN",
  "statusCheckRollup": [
    {"name": "Rust Backend (Axum)", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"name": "React 19 Frontend (SPA)", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"name": "Flutter Client (Android / TV)", "status": "COMPLETED", "conclusion": "SUCCESS"}
  ]
}
```
REST API output:
```json
{"mergeable": true, "mergeable_state": "clean"}
```

---

### Phase 3: Cleanup & Teardown

- Command: `gh pr close 14 --delete-branch`
- Output:
  ```
  ✓ Closed pull request anis7t/anis-home-media-server#14 (test: branch protection verification probe)
  ✓ Deleted branch test/branch-protection-probe and switched to branch main
  ```
- Local git repository status: cleanly on branch `main` with zero orphaned branches or unmerged commits.
