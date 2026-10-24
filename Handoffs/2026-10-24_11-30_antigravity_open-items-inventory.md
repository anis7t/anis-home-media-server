# Session Handoff — 2026-10-24 11:30 IST

**Author / Agent:** Antigravity (Advanced Agentic Pair Programmer)  
**Topic:** Repository Documentation Inventory, Phase 11 Reconciliation & Open Items Register  
**Branch:** `feat/rust-react-postgres-migration`

---

## 1. Executive Summary

This session performed a comprehensive cross-repository documentation sweep, reconciled completed milestones against actual runtime code, and established a durable **Active Open Items & Pending Decisions Register** in [`docs/PROJECT_STATUS.md`](file:///e:/MediaServer/docs/PROJECT_STATUS.md) and in this handoff to ensure zero loss of context across future agent and operator sessions.

---

## 2. Documentation Landscape & Structure

The repository maintains **124+ markdown documents** under [`docs/`](file:///e:/MediaServer/docs), root guidelines, and **57 session handoffs** in [`Handoffs/`](file:///e:/MediaServer/Handoffs):

| Documentation Group | Key Files | Purpose |
|---|---|---|
| **Living Sources of Truth** | [`AGENTS.md`](file:///e:/MediaServer/AGENTS.md)<br>[`GEMINI.md`](file:///e:/MediaServer/GEMINI.md)<br>[`docs/PROJECT_STATUS.md`](file:///e:/MediaServer/docs/PROJECT_STATUS.md)<br>[`docs/DEVELOPMENT_STATUS.md`](file:///e:/MediaServer/docs/DEVELOPMENT_STATUS.md)<br>[`docs/Current issues.md`](file:///e:/MediaServer/docs/Current%20issues.md)<br>[`docs/FLUTTER_CLIENT_STATUS.md`](file:///e:/MediaServer/docs/FLUTTER_CLIENT_STATUS.md) | Universal system invariants, safety guardrails (Windows process probing, headless test rules), master project status, living issue resolution log, and client runtime architecture. |
| **Architecture & Specifications** | [`docs/openapi.yaml`](file:///e:/MediaServer/docs/openapi.yaml)<br>[`docs/OPENING_SEQUENCE.md`](file:///e:/MediaServer/docs/OPENING_SEQUENCE.md)<br>[`docs/MULTI_GPU_CHUNKED_TRANSCODING_PROPOSAL.md`](file:///e:/MediaServer/docs/MULTI_GPU_CHUNKED_TRANSCODING_PROPOSAL.md)<br>[`docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md`](file:///e:/MediaServer/docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md)<br>[`docs/BACKUP_AND_RESTORE.md`](file:///e:/MediaServer/docs/BACKUP_AND_RESTORE.md) | OpenAPI 3.1 contract shapes, brand intro canonical specification (Part I), autonomous dual-GPU chunked transcoding engine, and PostgreSQL 18.4 `pg_dump -Fc` runbook. |
| **Modernization & Migration** | [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](file:///e:/MediaServer/docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md)<br>[`docs/MIGRATION_STATUS.md`](file:///e:/MediaServer/docs/MIGRATION_STATUS.md)<br>[`docs/PHASE_10_WALKTHROUGH.md`](file:///e:/MediaServer/docs/PHASE_10_WALKTHROUGH.md)<br>[`docs/PHASE_11_OPENING_SEQUENCE_PLAN.md`](file:///e:/MediaServer/docs/PHASE_11_OPENING_SEQUENCE_PLAN.md) | Complete roadmap and walkthroughs covering Phases 0–11. 100% Rust/Axum + React 19 + PostgreSQL 18.4 complete; Flask/Waitress/SQLite fully decommissioned. |
| **Operational & Ingress** | [`docs/STATIC_IP_MIGRATION_WALKTHROUGH.md`](file:///e:/MediaServer/docs/STATIC_IP_MIGRATION_WALKTHROUGH.md)<br>[`docs/CADDY_HTTPS_WALKTHROUGH.md`](file:///e:/MediaServer/docs/CADDY_HTTPS_WALKTHROUGH.md)<br>[`docs/NETWORK_BENCHMARK_2026-10-22.md`](file:///e:/MediaServer/docs/NETWORK_BENCHMARK_2026-10-22.md)<br>[`docs/ANDROID_APP_DISTRIBUTION.md`](file:///e:/MediaServer/docs/ANDROID_APP_DISTRIBUTION.md) | Public static IP cutover, Caddy Let's Encrypt DNS-01 reverse proxy, router NAT table management, and universal APK publishing. |
| **Triage & Post-Mortems** | [`docs/QR_SIGNIN_WALKTHROUGH.md`](file:///e:/MediaServer/docs/QR_SIGNIN_WALKTHROUGH.md)<br>[`docs/TRIAGE_01_WATCH_HISTORY.md`](file:///e:/MediaServer/docs/TRIAGE_01_WATCH_HISTORY.md) to [`06_ADD_DEVICE_FLOW.md`](file:///e:/MediaServer/docs/TRIAGE_06_ADD_DEVICE_FLOW.md)<br>[`Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md`](file:///e:/MediaServer/Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md) | Detailed triage writeups for user-reported bugs (Issues 1–14), security hardening of QR and token flows, and GPU hardware crash post-mortems. |

---

## 3. Active Open Items, Pending Decisions & System Backlog

All historical migration phases (0–10) and triage items (Issues 1–11, 14.1–14.6) are **resolved**. The active items across the repository fall into five distinct categories:

### Category 1: Phase 11 Brand Opening Sequence — Physical Device Verification
* **Current State:** Slices 11.1 through 11.8 are **100% implemented and verified** in automated suites:
  - **Web:** Canonical React 19 canvas `renderAt(t)` + Web Audio score (`web/src/lib/intro/`, `BrandIntroOverlay.tsx`) verified frame-for-frame by Playwright pixel oracles (`web/e2e/intro-frame.spec.ts`) and audio graph assertions (`web/e2e/intro-audio.spec.ts`).
  - **Android Phone:** Flutter `CustomPaint` with all 7 FX layers above the obsidian curtain, responsive portrait/landscape breakpoint, and byte-for-byte `intro-theme.wav` score via `audioplayers`.
  - **Android TV:** 60fps pre-rendered H.264 video (`media_kit`) on PowerVR GE8300 GPU, completely eliminating the 1.09s first-frame Skia runtime shader jank.
  - **Hardening:** Wordmark ambient style override (`TextDecoration.none`), 2.57s touch handover, and removal of visible Skip/Replay controls.
* **Pending Action (Batched to End of Phase):**
  - Connect physical **Fire TV Stick 4K** (`AFTMM`) and **Vivo phone** via ADB.
  - Build universal release APK (`scripts/release_android.py`) and perform cold boot on both devices.
  - Confirm video smoothness on Fire TV, audio synchronization, clean ambient typography, and remote D-pad input absorption with seamless app handover.

### Category 2: GPU Hardware Stability & AMF Transcoder TDRs ([Issue 13](file:///e:/MediaServer/docs/Current%20issues.md#issue-13-the-amd-graphics-stack-is-chronically-unstable-and-the-amf-pipeline-provokes-it-2026-10-20))
* **Context:** The host AMD graphics stack has chronic driver instability (22+ GPU TDRs / Kernel error 141 in Windows WER log), provoked by high-load AMF hardware transcoding (`vpp_amf` / `h264_amf`). Playwright browser automation now enforces `--disable-gpu` to prevent host TDR resets.
* **Owner Decisions Required:**
  1. **GPU Driver Upgrade:** Decision whether to install AMD Adrenalin 26.5.2 (legacy WHQL release). Caution: Generic drivers risk misidentifying the Vega 8 as Vega 11 on this Acer hybrid laptop, and DDU clean installs risk black screens without external display backup.
  2. **Acceptance Stress Test:** Run a 2160p dual-GPU AMF stress test across 3 workers to verify zero `LiveKernelReports` dumps or worker drops.
  3. **HLS Cache Retention:** Maintain the 149 GB HLS cache on `E:` without premature pruning until GPU stability is settled (pruning forces immediate re-transcoding).

### Category 3: Decommissioning & System Hygiene ([Issue 12](file:///e:/MediaServer/docs/Current%20issues.md#issue-12-the-flaskwaitress-era-left-three-live-loose-ends-2026-10-20))
* **`media-db` MCP Server Migration:** The `media-db` MCP tool server currently points to `.opencode/db/media.snapshot.db` (retired SQLite snapshot from Phase 3). It must be reconfigured to read PostgreSQL 18.4 (`MediaServerPG` on port 5432) or retired so AI tools receive authoritative database state.
* **Legacy `MediaServer` Windows Service:** The legacy Flask/Waitress NSSM service registration `MediaServer` remains Stopped/Manual and points to a non-existent file (`run_production.py`). Needs owner approval to delete registration (`nssm remove MediaServer confirm`).
* **Stale External Directory:** `C:\Users\anis7\Documents\Anis-Media-Server-Intro\` (294 MB duplicate from pre-in-tree move) can be safely archived or deleted.

### Category 4: Owner Security & Credential Actions
* **Admin PIN Rotation:** Live `admin_pin` in PostgreSQL `settings` table is set to the default bootstrap value `791654`. Owner should rotate this to a personal secret via the Admin UI or SQL.
* **Cloudflare API Token Scoping:** The API token configured in Caddy (`Caddyfile.template`) for DNS-01 Let's Encrypt validation is currently account-wide; it should be restricted strictly to Zone DNS Edit for `media.anisparvez.in`.
* **Google Sign-In Post-Fix Verification:** Following the 2026-10-23 allowlist wipe, verify sign-in via browser with `anis7t@gmail.com` to confirm landing on `/account` with full admin privileges.

### Category 5: Architectural Backlog / Parked Debt
* **Per-User Progress Scoping (`progress` table):** Device presence and watch history are scoped per user (`devices.user_id`), but the legacy `progress` table (which stores raw video timeline position by filename) remains global. Scoping `progress` by `user_id` is noted as future debt.
* **Admin Mutation Audit Log:** Administrative mutations (device renames/unlinks, allowlist updates) are logged only to `rust_api.log`. A dedicated database audit log table was parked while single-admin operations suffice.
* **Proactive Subtitle Acquisition:** OpenSubtitles downloads are currently on-demand / manual rather than proactive on new library ingest.
* **Off-Host Database Backups:** Automated backups run daily at 03:00 to `E:\MediaServer\backups\postgres\`, but off-host synchronization (e.g. S3 / B2 / external drive) is not yet set up.

---

## 4. Documentation Changes Made in this Session

1. **[`docs/PROJECT_STATUS.md`](file:///e:/MediaServer/docs/PROJECT_STATUS.md)**:
   - Updated review date to `2026-10-24`.
   - Added Phase 11 row to the Modernization phase table: `✅ COMPLETE (Slices 11.1–11.8 Delivered; On-Device Physical Check Batched)`.
   - Inserted new top-level register: `## Active Open Items, Pending Decisions & System Backlog (2026-10-24)` detailing all 5 categories.
   - Updated items 14 and 15 under Recent Completed Deliverables to show Phase 11 implemented through Slice 11.8.
2. **[`Handoffs/2026-10-24_11-30_antigravity_open-items-inventory.md`](file:///e:/MediaServer/Handoffs/2026-10-24_11-30_antigravity_open-items-inventory.md)**: Created this persistent handoff.
