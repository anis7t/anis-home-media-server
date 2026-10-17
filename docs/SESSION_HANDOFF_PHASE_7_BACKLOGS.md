# Session Handoff: Post-Phase-9 Slices Complete & Phase 7 Backlog Execution Plan

## 1. Executive Summary & Current State
- **Branch**: `feat/phase-9-pre-transcode-capabilities` (All commits clean; working tree clean).
- **Core Production Stack**:
  - **Server**: `MediaServerRust` active on port `8000` (NSSM Windows Service).
  - **Database**: PostgreSQL 18.4 on port `5432` (`MediaServerPG`).
  - **Ingress**: Cloudflare Tunnel mapping `media.anisparvez.in` to `127.0.0.1:8000`.
  - **Web Client**: React SPA compiled cleanly into `web/dist/` and served directly by Axum.
  - **Test Suite Status**:
    - **119/119** Rust tests pass across 15 test suites.
    - **212/212** Web Vitest tests pass across 30 test files.
    - **22/22** Android client contract endpoints pass (`scripts/probe_android_api.py`).
    - TypeScript typecheck: **0 errors**.

---

## 2. Completed in This Session (Phase 9 Post-Implementation Slices A–D)

1. **Slice A (`/download` App Distribution)**:
   - Built native Rust endpoints `GET /api/app/download` (RFC 7233 byte-range streaming via `RangeService`) and `GET /api/app/update` (version manifest).
   - Created obsidian-glass `<DownloadPage>` at `/download`, `/app`, `/android` with Phone/TV cards, version pill `v1.2.20`, and SHA-256 fingerprint verification.
   - Walkthrough: [`docs/SLICE_A_WALKTHROUGH.md`](SLICE_A_WALKTHROUGH.md) (commit `6cdc0ff`).
2. **Slice B (Google Sign-In 503 Resolution & Admin PIN Fallback)**:
   - Added `oauth_configured` probe flag to `/api/auth/me`.
   - Redirected unconfigured `/auth/google` requests to `/account?error=oauth_unconfigured`.
   - Implemented `POST /api/auth/login-pin` with constant-time comparison against `settings.admin_pin`, upserting `admin_pin` account and minting 30-day session token cookie.
   - Built `<AdminPinSignInModal>` portaled to `document.body` with input, `.env` setup instructions, and keyboard navigation.
   - Walkthrough: [`docs/SLICE_B_WALKTHROUGH.md`](SLICE_B_WALKTHROUGH.md) (commit `e4a423b`).
3. **Slice C (Subtitle Delay Flicker Elimination)**:
   - Made `applySubStyles` idempotent to guard against redundant `<style id="cue-styles">` DOM writes in `document.head`.
   - Decoupled `useSubtitles` into 3 separate effects (visual CSS, cue layout, and timing offset).
   - Non-destructive `applyCueTiming` shifts `c.startTime` and `c.endTime` dynamically with zero cue layout thrash or flicker.
   - Synchronous `adjustOffset` calculation and debounced `localStorage` persistence (300ms).
   - Walkthrough: [`docs/SLICE_C_WALKTHROUGH.md`](SLICE_C_WALKTHROUGH.md) (commit `8af2022`).
4. **Slice D (Native 4K HEVC Direct Play Unlock via W3C Media Capabilities)**:
   - Made `normalizeVideoCodecMime` dimension-aware, outputting `hvc1.1.6.L150.90` (Level 5.0 Main 10) for 4K HEVC and `avc1.640033` (Level 5.1) for 4K H.264.
   - Fed real video dimensions into `navigator.mediaCapabilities.decodingInfo()` with dual-tag fallback (`hvc1` / `hev1`).
   - Connected `result.width` and `result.height` in `PlayerPage.tsx`.
   - Walkthrough: [`docs/SLICE_D_WALKTHROUGH.md`](SLICE_D_WALKTHROUGH.md) (commit `62d4984`).
5. **Developer Experience (SQLTools)**:
   - Configured VS Code SQLTools PostgreSQL connection to `localhost:5432` (`MediaServerPG`) in `.vscode/settings.json`.
   - Walkthrough: [`docs/SQLTOOLS_POSTGRESQL_CONNECTION_WALKTHROUGH.md`](SQLTOOLS_POSTGRESQL_CONNECTION_WALKTHROUGH.md) (commit `d7c814d`).

> [!NOTE]
> **Clarification on "Slice E" vs "Slice 7E":**
> There was **no Slice E** in the active issues queue. The active issues plan (`docs/ACTIVE_ISSUES_IMPLEMENTATION_PLAN.md`) addressed exactly 4 issues through Slices A, B, C, and D. All 4 are complete.
> The remaining modernization backlog is **Slice 7E** ("Legacy Flask Retirement & Final Sign-Off") under Phase 7.

---

## 3. Paste-Ready Resume Prompt for New Session

Copy and paste the block below into a new session to resume work on the Phase 7 backlog:

```text
Resume work on Anis' Home Media Server at E:\MediaServer.

STATE
- Branch: feat/phase-9-pre-transcode-capabilities (latest commit: c505e14). Pushing is reserved for the user.
- Production Stack:
  - Rust Axum on port 8000 (MediaServerRust NSSM service).
  - PostgreSQL 18.4 on port 5432 (MediaServerPG).
  - React SPA served directly from web/dist/ on port 8000.
  - Cloudflare Tunnel routing media.anisparvez.in -> 127.0.0.1:8000.
- Test Battery Status:
  - 119/119 Rust tests pass across 15 test suites.
  - 212/212 Web Vitest tests pass across 30 test files.
  - 22/22 Android client contracts pass (scripts/probe_android_api.py).
  - TypeScript tsc -b: 0 errors.
  - Vite build: clean (792ms).

COMPLETED IN PREVIOUS SESSIONS:
1. Phase 9 (Client Media Capabilities, Offline Pre-Transcode Architecture & 100% Gating) - commit 22feeaf.
2. Active Issues Slices A–D:
   - Slice A: /download App Distribution & native Axum APK streaming (6ba1e3a, 6cdc0ff).
   - Slice B: Google Sign-in 503 fix & local Admin PIN fallback modal (e4a423b).
   - Slice C: Subtitle delay flicker elimination via decoupled layout & idempotent CSS (8af2022).
   - Slice D: Native 4K HEVC Direct Play unlock via dimension-aware W3C probe (62d4984).
   - DX: VS Code SQLTools PostgreSQL profile configured (d7c814d).

NEXT OBJECTIVE — PHASE 7 BACKLOG (SLICE 7E: LEGACY FLASK RETIREMENT):
Execute Phase 7 Slice 7E per docs/SESSION_HANDOFF_PHASE_7_BACKLOGS.md:
1. Audit residual Python scripts & imports to ensure no active operational tooling relies on legacy Flask modules (app/routes/*, app/services/*).
2. Decommission deprecated legacy app/ directory (Flask controllers, Jinja templates, Waitress WSGI wrappers) and wsgi.py per AGENTS.md §0.2.
3. Prune requirements.txt (remove Flask, Waitress, Flask-CORS; retain only libraries needed by standalone operational scripts e.g. psycopg2-binary, requests).
4. Run full 15-suite Rust & 30-suite Vitest battery; verify documentation reflects 100% Rust + React + PostgreSQL architecture; complete final modernization sign-off.

READ FIRST, IN THIS ORDER:
- AGENTS.md §0.1 & §0.2 (Standing rules: Ask before planning, present plan, approve before coding; Flask is deprecated).
- GEMINI.md (Process safety, task management, cross-drive rules).
- docs/SESSION_HANDOFF_PHASE_7_BACKLOGS.md (detailed Slice 7E execution plan).
- Handoffs/2026-10-18_02-40_antigravity_slices-a-d-complete-and-slice-7e-plan.md.
- docs/PROJECT_STATUS.md (authoritative project and roadmap status).
```

---

## 4. Scope for Upcoming Session: Phase 7 Backlogs (Slice 7E)

Per [`docs/MIGRATION_STATUS.md`](MIGRATION_STATUS.md) and [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §5 (Phase 7), Slices 7A through 7D are complete. The remaining backlog is **Phase 7 Slice 7E: Legacy Flask Retirement & Final Modernization Sign-Off**:

### Objectives for Slice 7E
1. **Audit Residual Python Dependencies & Imports**:
   - Verify that no active operational tooling or production scripts depend on legacy Flask modules (`app/routes/*`, `app/services/*`).
   - Identify standalone Python helper scripts that must remain (e.g. `scripts/probe_android_api.py`, transcode benchmarks) vs obsolete Flask wrappers.
2. **Decommission Deprecated Flask Codebase (`app/`)**:
   - Retire legacy `app/` directory (Flask controllers, Jinja templates, Waitress WSGI wrappers) per `AGENTS.md` §0.2.
   - Archive or remove `wsgi.py` and old Flask launcher scripts.
3. **Prune Dependencies (`requirements.txt`)**:
   - Remove Flask, Waitress, Flask-CORS, and legacy web packages from Python requirements.
   - Keep only libraries needed by operational scripts (e.g., `psycopg2-binary` or `requests` for contract probes).
4. **Final Modernization Sign-Off**:
   - Run full 15-suite Rust test battery and 30-suite Vitest battery.
   - Verify that all operational documentation (`AGENTS.md`, `README.md`, `docs/`) accurately reflects the 100% Rust + React + PostgreSQL architecture.
   - Formally sign off on the complete Flask retirement!

---

## 5. Key Architectural Invariants to Uphold
- **Rule 1 (Planning Protocol)**: Before executing any code changes for Slice 7E, create a formal `/plan` artifact, request feedback, and await user approval (`AGENTS.md` §0.1, `GEMINI.md` §0).
- **Rule 2 (No Flask Resurrections)**: Flask is deprecated. No new Python endpoints may be introduced. All services run on Rust (`rust/`) and React (`web/`).
- **Rule 3 (Drive Tiering)**: Runtime workspace at `E:/MediaServer`, SQLite deprecated, media storage strictly at `D:/Flicks`.
- **Rule 4 (Git Hygiene)**: Agent commits locally; `git push` is reserved exclusively for the user.
- **Rule 5 (Port 8000 Invariant)**: Axum serves API endpoints on `/api/*`, media streams on `/media/*`, HLS on `/hls/*`, and SPA assets from `web/dist/` on port `8000`.
