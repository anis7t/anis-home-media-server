# Implementation Plan: GitHub Branch Protection for `main`

## Context & Objectives
Following the successful implementation and verification of the 3-pillar CI pipeline (Rust Backend, React Frontend, Flutter Client), the repository `anis7t/anis-home-media-server` currently has no branch protection configured on `main` (`gh api repos/.../branches/main/protection` returns HTTP 404).

This plan configures production branch protection for `main` via the GitHub API to enforce that all 3 CI jobs must pass on Pull Requests before merging, while preserving repository maintainer and automated agent workflow flexibility.

---

## Proposed Architecture & Configuration

We will apply branch protection to `main` via GitHub REST API:
`PUT /repos/anis7t/anis-home-media-server/branches/main/protection`

```json
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Rust Backend (Axum)",
      "React 19 Frontend (SPA)",
      "Flutter Client (Android / TV)"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
```

### Key Configuration Rationale:
1. **Strict Up-To-Date Enactment (`strict: true`):** Requires PR branches to be updated with the latest commit on `main` before merging, preventing regression drift.
2. **Explicit 3-Pillar Contexts:** Mandates green status checks from:
   - `Rust Backend (Axum)`
   - `React 19 Frontend (SPA)`
   - `Flutter Client (Android / TV)`
3. **Maintainer & Agent Flexibility (`enforce_admins: false`, `required_pull_request_reviews: null`):**
   - Allows the sole repository owner/maintainer to merge PRs without requiring a second human reviewer.
   - Allows emergency direct pushes by the repository administrator/authenticated agent when explicitly intended.

---

## Scope

### In Scope:
- Applying branch protection on `main` using GitHub CLI (`gh api`).
- Verifying the live configuration via `gh api repos/anis7t/anis-home-media-server/branches/main/protection`.
- Updating documentation in [`docs/TESTING.md`](TESTING.md) and [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md) to record the active branch protection rules.
- Committing and pushing documentation updates to `main`.

### Out of Scope:
- Blocking direct pushes for administrators (`enforce_admins: true`).
- Requiring approvals from other reviewers (`required_pull_request_reviews`).
- Modifying repository code or workflow files.

---

## Exit Criteria
1. `gh api repos/anis7t/anis-home-media-server/branches/main/protection` returns HTTP 200 with:
   - `required_status_checks.strict == true`
   - `required_status_checks.contexts` containing all 3 required job names.
   - `enforce_admins.enabled == false`.
2. Documentation updated and synced on `main`.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Mismatched check names prevent PR merges | High | Check names match the exact YAML `name` fields: `Rust Backend (Axum)`, `React 19 Frontend (SPA)`, `Flutter Client (Android / TV)`. |
| Solo maintainer blocked by review requirement | High | `required_pull_request_reviews` explicitly set to `null` so external approval is not demanded. |
| Admin locked out from hotfixes | Medium | `enforce_admins: false` ensures owner retains administrative override. |
