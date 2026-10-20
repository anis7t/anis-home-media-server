# Slice 7E Walkthrough: Legacy Flask Retirement & Final Modernization Sign-Off

**Date:** 2026-10-18  
**Scope:** Phase 7 Backlog — Sub-Slices 7E.1 through 7E.5  
**Status:** ✅ 100% Complete, Verified & Signed Off  
**Target Stack:** 100% Rust (Axum, port 8000) + React 19 SPA (`web/dist/`) + PostgreSQL 18.4 (`MediaServerPG`, port 5432)

---

## 1. Executive Summary

Slice 7E constitutes the final milestone of the entire Media Server modernization initiative. With all capabilities natively ported to Rust and React, and data persistence migrated to PostgreSQL 18.4, Slice 7E systematically dismantled and retired the legacy Python/Flask/Waitress stack, legacy Jinja templates, obsolete static assets, unneeded operational scripts, and legacy unit tests.

The decommissioning was divided into 5 sequential, independently verifiable sub-slices (7E.1 to 7E.5), removing over **42,000 lines** of legacy code while maintaining 100% uptime and backwards compatibility for web browsers, mobile clients, and Android/Fire TV devices.

---

## 2. Sub-Slice Execution Breakdown

### Sub-Slice 7E.1: Operational Scripts Audit & Tooling Modernization
- **Commit:** `9e75ee2`
- **Actions:**
  - Audited 54 files in `scripts/`.
  - Preserved 17 active operational and testing scripts:
    - Client testing: `scripts/probe_android_api.py`, `scripts/probe_phase_8_contracts.py`
    - Service management: `scripts/service_status.ps1`, `scripts/restart_rust_service.bat`, `scripts/restart_rust_service.ps1`
    - PostgreSQL operations: `scripts/backup_postgres.bat`, `scripts/backup_postgres.ps1`, `scripts/restore_postgres.py`, `scripts/verify_postgres_data.py`
    - Flutter client: `scripts/run_flutter_tests.ps1`
    - Benchmarking: `scripts/benchmark_streaming.py`
  - Decommissioned 30 obsolete scripts:
    - Flask/Waitress service installers: `install_service.*`, `uninstall_service.*`, `service_watchdog.*`
    - Legacy migration scripts: `cutover_port_8000.*`, `migrate_sqlite_to_postgres.py`
    - Legacy HLS / transcode debuggers: `hls_chunk_inspector.py`, `hls_debug_monitor.py`, `hls_stalls_audit.py`, `hls_verify_stream.py`
  - Modernized `scripts/service_status.ps1` to query only active production services: `MediaServerRust`, `MediaServerPG`, and `Cloudflared`.
- **Walkthrough:** [`docs/SLICE_7E_1_WALKTHROUGH.md`](SLICE_7E_1_WALKTHROUGH.md)

### Sub-Slice 7E.2: Legacy Templates & Static Assets Retirement
- **Commit:** `5a2af4f`
- **Actions:**
  - Decommissioned all 9 legacy Jinja HTML templates in `templates/` (7,747 lines):
    - `templates/library.html`, `templates/player.html`, `templates/details.html`, `templates/devices.html`, `templates/manage.html`, `templates/manual.html`, `templates/intro-overlay.html`, `templates/cast-debug.html`, `templates/base.html`.
  - Decommissioned legacy `static/` asset directory (`static/css/`, `static/js/`, `static/vendor/`).
  - Removed template-era diagnostics: `tmdb_test.py`, `tmdb_diag.py`, `tmdb_details_test.py`, `restart_service_for_cast.cmd`.
  - Verified React SPA (`web/dist/`) serves all pages directly without dependency on server-side Jinja templates.
- **Walkthrough:** [`docs/SLICE_7E_2_WALKTHROUGH.md`](SLICE_7E_2_WALKTHROUGH.md)

### Sub-Slice 7E.3: Legacy Python Backend Decommissioning & `scanner.py` Decoupling
- **Commit:** `c5ee97d`
- **Actions:**
  - Decoupled `scanner.py` into a 100% standalone ingestion utility:
    - Implemented direct PostgreSQL connectivity via `psycopg` (with SQLite fallback).
    - Added query parameter tokenization (`?` -> `%s`).
    - Embedded native poster download routine, removing dependencies on `app.db` and `posters.py`.
    - Preserved exact sub-process interface invoked by Rust's `rust/src/services/scanner.rs`.
  - Decommissioned entire `app/` directory tree (35 files, 15,355 lines of code):
    - All routes (`app/routes/*.py`), services (`app/services/*.py`), configuration (`app/config.py`), database layer (`app/db.py`), utilities (`app/utils/*.py`).
  - Decommissioned root WSGI launchers: `app.py`, `run_production.py`, `gunicorn.conf.py`, `posters.py`, `server.sh`.
- **Walkthrough:** [`docs/SLICE_7E_3_WALKTHROUGH.md`](SLICE_7E_3_WALKTHROUGH.md)

### Sub-Slice 7E.4: Test Suite Modernization & Requirements Pruning
- **Commit:** `5d0fbb3`
- **Actions:**
  - Pruned `requirements.txt`:
    - Removed: `Flask`, `waitress`, `gunicorn`, `WMI`, `pywin32`.
    - Retained: `requests`, `python-dotenv`, `psycopg[binary]`, `psycopg-pool`.
    - Installed operational dependencies globally in the active Python environment.
  - Decommissioned 52 obsolete Python test files in `tests/` (19,706 lines of code):
    - Removed `tests/test_*.py`, `tests/conftest.py`, and `tests/integration/`.
  - Strictly preserved `tests/load/` benchmark records and historical telemetry JSON artifacts.
- **Walkthrough:** [`docs/SLICE_7E_4_WALKTHROUGH.md`](SLICE_7E_4_WALKTHROUGH.md)

### Sub-Slice 7E.5: Architectural Documentation Modernization & Final Sign-Off
- **Commit:** (Current)
- **Actions:**
  - Modernized `AGENTS.md`:
    - Rule 0.2: Marked Flask and Waitress as permanently decommissioned; stack is 100% Rust + React.
    - Section 1 (Project Identity): Updated to 100% Rust/Axum (`:8000`) + React 19 SPA + PostgreSQL 18.4 (`MediaServerPG`).
    - Section 2 (Current Architecture): Replaced legacy ASCII diagram with modern Axum/SQLx/React topology.
    - Section 4 & 5 (Roadmap & Platform Rules): Updated persistent service rules to `MediaServerRust` via NSSM and `scripts/restart_rust_service.bat`.
    - Section 7 (Testing Protocol): Updated to `cargo test`, `npm run test`, and live probe scripts.
    - Section 9 (Invariants): Updated Native Independence Invariant to reflect full independence.
  - Modernized `README.md`:
    - Updated project overview, stack summary, architecture diagram, hosting prerequisites, service control scripts, configuration (.env), and testing section.
  - Updated Roadmap Trackers:
    - `docs/PROJECT_STATUS.md`: Marked Phase 7 as `✅ COMPLETE — Slices 7A–7E Delivered & Verified`.
    - `docs/MIGRATION_STATUS.md`: Added top-level session handoff documenting 100% completion of the modernization.

---

## 3. Verification & Test Battery Results

A full multi-tier regression battery was executed across all components:

| Tier | Component | Command | Result |
|---|---|---|---|
| 1 | Rust Backend Unit & Integration Tests | `cargo test --manifest-path rust/Cargo.toml -- --test-threads=1` | **119/119 Passed** (15 test suites) |
| 2 | React SPA Unit Tests | `cd web && npm run test` | **212/212 Passed** (30 test files) |
| 3 | React Production Build | `cd web && npm run build` | **Clean Build** (792ms, 0 errors) |
| 4 | Client Contract Stability (Android / Fire TV) | `python scripts/probe_android_api.py` | **22/22 Endpoints OK** |
| 5 | Phase 8 Streaming Contracts | `python scripts/probe_phase_8_contracts.py` | **ALL PASSED** |
| 6 | Service Status Verification | `powershell scripts/service_status.ps1` | `MediaServerRust` (Running), `MediaServerPG` (Running), `Cloudflared` (Running) |

---

## 4. Final Architecture State

```text
Browser / Client (Desktop, Tablet, Mobile) / Android App / Fire TV Stick 4K
                   │
                   ▼
       Cloudflare Named Tunnel (media.anisparvez.in)
                   │
                   ▼
       Rust Axum Server (127.0.0.1:8000) [MediaServerRust NSSM Service]
                   │
    ┌──────────────┼──────────────────────────────┐
    ▼              ▼                              ▼
 React 19 SPA   API Router                  Transcode Engine
 (web/dist/)    ├─ api.rs (catalog/system)  ├─ planner.rs
                ├─ auth.rs (pin/session)    ├─ queue.rs
                ├─ media.rs (RFC 7233)      ├─ engine.rs (dual-GPU)
                ├─ hls.rs (fMP4/quality)    └─ sweeper.rs
                ├─ subtitles.rs (native)
                ├─ download.rs (APK stream)
                └─ manage.rs (storage)
                   │
    ┌──────────────┴──────────────────────────────┐
    ▼                                             ▼
PostgreSQL 18.4 (MediaServerPG, port 5432)   Local Media Roots
(E:\pgdata\ - movies, progress, settings)    ├─ D:\Flicks (raw media)
                                             ├─ D:\Flicks\.archive
                                             └─ D:\Flicks\.uploads
```

---

## 5. Modernization Sign-Off

The modernization of **Anis' Home Media Server** is officially **COMPLETE**.
All 10 roadmap phases (P0–P9, including Slices 7A–7E) are fully implemented, verified, and running in production. Legacy Flask, Waitress, Jinja, and SQLite have been completely replaced with a high-performance, robust, and maintainable Rust, React, and PostgreSQL foundation.

> **Amended 2026-10-20 — see §6.** The *architecture* claim above holds. The *feature parity*
> claim did not: one web feature was lost in Sub-Slice 7E.2 and never replaced. The modernization
> was complete in every respect except that one, and the sign-off did not look for it.

---

## 6. Post-Sign-Off Finding — a feature lost in 7E.2 and never replaced

**Found:** 2026-10-20, by review, two days after the cutover.
**Status:** open — tracked as a missed backlog item from this migration.

### What was lost

The **web brand opening sequence** (the 3-second intro overlay). It shipped in the Flask era as a
Jinja2 template, `templates/intro-overlay.html`, included at the end of the library page.
Sub-Slice 7E.2 retired nine legacy templates, that one among them, and **no React component was
written to replace it**.

```text
a10e9ef  feat(intro): wire the brand opening sequence into the library page
107220f  chore: sync latest development
5a2af4f  refactor(ui): decommission legacy Jinja templates and static assets (Slice 7E.2)   <- deleted
```

`web/src` contains no overlay component, and a search across **all branches and all of history**
finds no React component that ever existed. The web app has had no intro since 2026-10-18.

### Why the sign-off missed it

7E.2's verification was: *"Verified React SPA (`web/dist/`) serves all pages directly without
dependency on server-side Jinja templates."* That is an **architecture** check — and it passed.
What it did not ask was whether the SPA still had the **features** the templates carried.

The sign-off's own objective 4 was *"Verify that all operational documentation accurately reflects
the 100% Rust + React + PostgreSQL architecture."* It did — accurately. The problem was that
`AGENTS.md` and `docs/OPENING_SEQUENCE.md` both asserted the overlay *was* implemented, naming a
file (`web/src/components/BrandIntroOverlay.tsx`) that **has never existed on any branch**. So the
documentation verified the architecture and, at the same time, misdescribed the feature — and every
later reader had a reason to believe nothing was missing.

**This is the generalisable lesson: a decommissioning sign-off must diff *capabilities*, not just
*mechanisms*.** "The template is gone and the SPA serves the page" is not the same claim as "the
feature is still there", and only the second one is what a user would notice.

### What was not lost

- **The Flutter client still has it** — `flutter_client/lib/features/intro/`, with its own copy of
  `intro-demo-portrait.mp4` and two test files. It was never affected.
- **All the assets are intact** — `docs/opening-sequence/`, 293 MB: both videos, the score, 180
  captured PNG frames, the stills, and the original source HTML.
- **The design and the invariants are intact** — `docs/OPENING_SEQUENCE.md` and the AGENTS.md
  "Brand Opening Sequence (Intro Overlay) Invariants" block.

So the port is a **well-specified piece of work with a working reference implementation**, not a
redesign.

### The corrective actions taken on 2026-10-20

| Document | Correction |
|---|---|
| `AGENTS.md` | The false claim that the overlay is *"wired into the React SPA in `web/src/components/BrandIntroOverlay.tsx`"* is removed. The three web invariants are now explicitly labelled **the specification for a port that has not been written**, and the Flutter invariant is labelled **implemented**, with its file paths. |
| `docs/OPENING_SEQUENCE.md` | New §0 records the loss, the evidence, the timeline and what survives. The status line no longer claims the overlay is wired in. §5's Jinja include is annotated as historical, with the port's requirement stated. |
| `AGENTS.md` §1 work queue | The web port is now item 5 of the immediate queue. |
| `docs/Current issues.md` | Recorded as Issue 10. |

### The port, when it is done

- **Rust/Axum:** serve the three runtime media files (~5 MB) from `web/public/`. The 280 MB of
  captured PNG frames is re-render source material and does not need to ship.
- **React:** a component that injects the overlay over the running app — *not* a snapshot of it —
  honours the three web invariants, and gates once per browser session on the **container**, not
  the overlay.
- **Regression harness:** `docs/opening-sequence/scripts/serve_with_intro.py` injects the overlay
  over the running app independently of the app's own code, so the ported component can be
  compared against the reference rendering frame for frame.
