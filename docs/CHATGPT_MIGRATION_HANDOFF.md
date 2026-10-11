# ChatGPT Handoff — Media Server PostgreSQL Migration

Last updated: 2026-10-10

## Repository identity

- Verified GitHub repository: https://github.com/anis7t/anis-home-media-server
- Default branch reported by GitHub: `main`
- The branch `feat/rust-react-postgres-migration` and commit `9766edc` were referenced by prior local-session reports, but GitHub lookup did not find that branch. Treat the local branch and HEAD as unverified until checked in the user's actual working copy.
- Never assume GitHub's default branch contains local uncommitted work. Remote files do not show a developer's working tree.

## Project overview

A Windows-hosted Flask/Waitress media server with SQLite, HTTP range streaming, HLS/FFmpeg transcoding, dual AMD GPU chunk transcoding (Radeon RX 560X and Vega 8), TMDb metadata, resumable uploads, per-device watch progress, storage management, and Flutter/Android/Fire TV clients. Production service is reported as a Windows service named `MediaServer`, serving on localhost port 8000 and exposed via Cloudflare Tunnel.

Paths reported by previous local audits:
- Current working directory at audit time: `E:\MediaServer` (verify; historical reports also mentioned `C:\MediaServer`)
- SQLite DB: `E:\MediaServer\media.db`
- Media root: `D:\Flicks`
- Python venv: `E:\MediaServer\venv`

## Migration objective

Incrementally migrate from Flask + SQLite toward React + TypeScript + Vite, Rust/Axum/Tokio/SQLx, and PostgreSQL, while keeping the existing Flask API and Flutter/TV clients working throughout the transition.

Critical invariants:
- Do not break the existing OpenAPI/API contracts or active clients.
- Preserve HTTP byte-range delivery, HLS, resumable chunk uploads, per-device progress and watch history.
- Preserve dual-GPU FFmpeg chunk-transcode behavior.
- Keep SQLite as the default until PostgreSQL integration is proven and a separately approved cutover plan exists.
- Preserve all data, including orphaned watch-progress rows that have no matching movie row.
- Never blindly revert to a stale SQLite copy after PostgreSQL has accepted writes.
- Do not stage, stash, reset, revert, or commit pre-existing changes without explicit authorization.

## Migration documentation to inspect in the working repository

Verify that these paths exist and read their current contents:
- `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`
- `docs/PHASE_0_ARCHITECTURE_AUDIT.md`
- `docs/MIGRATION_STATUS.md`
- `docs/openapi.yaml`
- `tests/test_api_contracts.py`

The previous report said Phase 0 architecture audit and Phase 1 OpenAPI contract work were completed. A prior Phase 1 report claimed 15 contract tests passed. Re-verify all claims against current files and test output.

## Prior Stage 1 implementation report — NOT independently verified here

The previous Antigravity report claimed Stage 1 added:
- `app/config.py`: `DATABASE_BACKEND` defaulting to SQLite, `DATABASE_URL`, allowed backend list.
- `app/db.py`: token-aware SQL placeholder conversion, PostgreSQL pool, `PostgresSession`, backend dispatch and pool shutdown.
- `requirements.txt`: `psycopg[binary]>=3.2.0,<4` and `psycopg-pool>=3.2.0,<4`.
- `tests/test_db_adapter.py`: 23 tests.

That report claimed these tests passed:
- Adapter tests: 23
- API contracts: 15
- Selected core regressions: 85
- Total: 123 passed

These are reported figures, not independently confirmed. No real PostgreSQL integration test was reported. Do not claim PostgreSQL compatibility solely on the basis of SQLite tests.

## Data facts from prior local audit — re-verify before relying on them

The prior audit reported these SQLite row counts:
- `schema_migrations`: 1
- `movies`: 43
- `progress`: 30
- `devices`: 335
- `device_watch_history`: 103
- `ip_cache`: 267
- `settings`: 1
- `device_progress`: 0
- Orphaned `device_watch_history` filenames absent from `movies`: 38
- Orphaned `progress` filenames absent from `movies`: 8
- Watch-history rows referencing a missing device: 0

The previous audit recommended retaining `movies.details_json` as TEXT for the initial PostgreSQL stage, because existing callers pass it to `json.loads()`.

## Existing working-tree changes reported before Stage 1

The prior report identified pre-existing changes in:
- `.vscode/settings.json`
- `GEMINI.md`
- `app/routes/media.py`
- Six Flutter registrant files
- `scripts/hls_frame_audit.py`
- `tests/test_storage_retention.py`
- Untracked `.vscode/settings.json.bak`
- Untracked `OPENCODE_CONFIG.md`

It also identified Stage 1 files:
- `app/config.py`
- `app/db.py`
- `requirements.txt`
- `tests/test_db_adapter.py`

This list is historical only. Run `git status` in the current working copy and rebuild the list; do not assume it remains accurate. A previously reported pre-existing assertion inversion in `tests/test_storage_retention.py` must not be silently modified.

## Technical risks to keep in view

1. Audit the actual SQL normalization implementation. A placeholder translator can mishandle SQL quoting/comments or PostgreSQL-specific syntax.
2. Confirm connection-pool checkout/return semantics, transaction cleanup, context-manager behavior, shutdown, and exceptions against real caller patterns.
3. Search for SQLite-only `INSERT OR IGNORE`, `INSERT OR REPLACE`, PRAGMAs, schema introspection, `lastrowid`, implicit transaction reliance, and other dialect-specific behavior.
4. Replacing `INSERT OR REPLACE` with `ON CONFLICT DO UPDATE` requires preserving the exact prior update semantics; do not mechanically translate.
5. Confirm `init_db()` behavior when PostgreSQL is selected. Stage 1 should not imply full PostgreSQL readiness if schema initialization or application SQL remains SQLite-specific.
6. Keep timestamps and JSON semantics consistent with current API consumers.
7. Do not run tests likely to write to the live DB or disrupt the service without safe fixture review.

## Known migration blockers previously reported

The previous report identified:
- `INSERT OR IGNORE` at `app/routes/upload.py`, `app/routes/api.py`, and `scanner.py`.
- `INSERT OR REPLACE` in `scanner.py`.
- `details_json` JSON decoding assumptions in `app/routes/pages.py` and `app/routes/api.py`.

Verify exact current locations and semantics before planning changes.

## Workflow instructions for ChatGPT

When starting a new session:
1. Treat this document as context, not proof of current repository state.
2. Use the connected GitHub repository when relevant, but remember it cannot show uncommitted local changes. For local implementation state, ask for the current audit report or `git status`/diff output from Antigravity.
3. Inspect authoritative migration docs, actual code and test fixtures before recommending implementation.
4. Prefer a read-only audit before authorizing new migration code.
5. Clearly distinguish facts verified from repository sources, historical report claims, and inferences.
6. Keep responses focused; do not restate the entire history unless useful.
7. For Antigravity prompts, write a self-contained prompt that can be pasted into Antigravity Desktop. The user is using Desktop, not CLI; do not give CLI launcher instructions.
8. Before writing code or recommending a cutover, state the scope and acceptance gates. Do not authorize production cutover without explicit approval.

## Current state and next step

At the time this handoff was prepared, the user had asked for a reusable ChatGPT handoff and to record it in the repository. The Stage 1 audit result from Antigravity had not yet been supplied in the visible conversation. Therefore, do not declare Stage 1 PASS, do not authorize Stage 2, and do not make code changes based on this document alone.

Recommended next step: review the output of the read-only Stage 1 verification audit, then determine whether the adapter is safe enough to proceed or needs narrowly scoped correction first.
