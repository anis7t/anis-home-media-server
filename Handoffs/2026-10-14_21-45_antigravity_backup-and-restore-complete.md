# Handoff — Anis' Home Media Server

| | |
|---|---|
| **Date** | 2026-10-14 21:45 IST (16:15 UTC) |
| **Agent** | Antigravity |
| **Model** | advanced-agentic-coding |
| **Workspace** | `E:\MediaServer` |
| **Branch** | `feat/react-web-frontend` — **not pushed**, ahead of `origin/feat/react-web-frontend` |
| **Code state** | Database Backup, Verification, Restoration Engine & Master Disaster Runbook delivered (`docs/BACKUP_AND_RESTORE.md`, `app/services/backup_service.py`, `scripts/backup_database.py`, `scripts/restore_database.py`, `scripts/backup_database.bat`, `tests/test_backup_restore.py`). Phase 3 migration critical gate unblocked; live baseline backup captured and dry-run recovery drill verified. |
| **Verified** | Backend Backup/Restore **8/8 passed**; Frontend **161/161 passed** (24 suites); Admin/Devices/Manage/Cast suites passing; Live backup & restore drill verified with 100% SQLite integrity. |
| **Pushed** | **No** — pushing is reserved for the user |

> This header deliberately names the **code** commits and session deliverables rather than a single `HEAD`:
> a handoff that states its own hash is wrong the moment it is committed. The next handoff should cite
> this newest file in `Handoffs/`.

---

## Paste-ready prompt

Copy everything inside the block below to start the next session.

---

```
Continue work on Anis' Home Media Server at E:\MediaServer.

STATE
- Branch feat/react-web-frontend, ahead of origin (NOT pushed). Pushing is reserved for the user.
- Code state:
  - Database Backup, Verification, Restoration Engine & Master Disaster Runbook DELIVERED:
    - app/services/backup_service.py: Zero-lock SQLite Online Backup API integration, crash-safe WAL handling, companion cryptographic manifest generation (.json) with SHA-256 and table row counts, atomic restore with pre-restore safety rollback points, Windows WAL/SHM sidecar cleanup, and retention rotation.
    - scripts/backup_database.py: Operator & cron CLI with custom labels, retention count (--keep), JSON output.
    - scripts/restore_database.py: Disaster recovery CLI with --backup latest, --force, --no-rollback, and integrity audits.
    - scripts/backup_database.bat: Windows Task Scheduler daily batch wrapper (03:00 daily).
    - docs/BACKUP_AND_RESTORE.md: Comprehensive 5-section master runbook covering crash safety, CLI guides, Task Scheduler recipes, disaster recovery, and Phase 3 PostgreSQL rollback window (<= 30s point of no return).
    - tests/test_backup_restore.py: 8/8 automated integration tests covering WAL backups, tamper detection, atomic restore, sidecar purging, pruning, metadata listing, and CLI execution.
    - Live Host Execution: Baseline backup captured at E:\MediaServer\backups\media_backup_20261014_160426_pre-migration-baseline.db (516,096 bytes, 852 rows across 11 tables), verified with live dry-run recovery drill.
  - Prior Work in Branch:
    - Issues 1–7 from docs/Current issues.md resolved (probe_hls_cache_instant(), Guest Mode auth model, passwordless TV pairing tokens, Admin PIN token minting, Watch History Drawer, Admin-only /manage gating, device IP privacy scoping).
    - Phase 2 React Web Frontend 100% complete against Flask backend (all Jinja templates retired; full 6-phase player parity with Cast remote hardening; modal dialogs portaled to document.body).
- Verified at HEAD:
  - Python Backup & Restore: pytest tests/test_backup_restore.py (8/8 passed).
  - Python Admin & Manage: pytest tests/test_admin_auth.py tests/test_devices.py tests/test_manage.py (57 passed, 3 subtests passed).
  - Python Cast API: pytest tests/test_cast_api.py (56/56 passed).
  - Frontend: 161/161 tests passed across 24 test files (npm test -- --run).
  - TypeScript: tsc -b passes with 0 errors.
  - Production Bundle: npm run build successfully built web/dist/.
- Live host: MediaServer + Cloudflared NSSM services. Server on 127.0.0.1:8000,
  published at https://media.anisparvez.in via a Cloudflare tunnel.
- You WILL need to restart the service (scripts\restart_service.bat, ELEVATED) after any
  edit under app/ - Waitress caches bytecode and does not reload.
- You WILL need `npm run build` after any edit under web/src - web/dist is the served
  artefact and nothing else rebuilds it.

READ FIRST, IN THIS ORDER
- AGENTS.md            - authoritative invariants, non-negotiable.
- GEMINI.md            - process safety, cross-drive rules, Cast & modal invariants.
- Handoffs\2026-10-14_21-45_antigravity_backup-and-restore-complete.md  - this document.
- docs\BACKUP_AND_RESTORE.md        - master database backup and recovery runbook.
- docs\MIGRATION_STATUS.md          - where the P0..P7 migration stands (Phase 3 unblocked).
- docs\PROJECT_STATUS.md            - dated work log, newest first (section 0).
- docs\FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md - the migration's shape and gates.

THE MIGRATION IS NOT WHAT YOU MIGHT ASSUME
- P0 audit, P1 OpenAPI contracts, P2 React web frontend: done (P2 complete against Flask).
- P3 PostgreSQL: code EXISTS (app/db.py has migrations, advisory locks, pool lifecycle).
  Phase 3 prerequisite (Backup & Restore drill + rollback window) is now DELIVERED & VERIFIED.
  Next step for P3 is authorized execution and verification against a real PostgreSQL instance.
- P4-P7 (Rust Axum API, Rust media, Rust transcoder, cutover): NOT STARTED. No rust/,
  no Cargo.toml.
- Jinja templates are GONE. Every page has a React equivalent.

WARNINGS THAT WILL BITE YOU
1. Windows SQLite WAL mode: Never copy or restore media.db without clearing media.db-wal and
   media.db-shm sidecars. Stale WAL files cause database disk image malformed errors. Always use
   backup_service.py or scripts\restore_database.py.
2. Cast Disconnect MUST call cast.quit_app() and cast.disconnect(). Halting media alone
   leaves the default media receiver running as an empty black screen on the TV.
3. Modal Dialog Portaling & CSS Transform Isolation: All modal dialogs MUST be portaled to
   document.body via createPortal(..., document.body). Page animations using forwards must terminate
   on `to { opacity: 1; transform: none; }` to prevent trapping position: fixed containing blocks.
4. The Admin PIN fails CLOSED and has no default. Never accept the PIN from a query string.
   Header (X-Admin-Pin) and JSON body only.
5. NEVER bare `flutter test` - use scripts\run_flutter_tests.ps1. It purges media_kit's
   orphaned temp state.
6. web/dist is the served artefact. Any change under web/src is invisible until npm run build runs.
7. Backend edits need an elevated service restart (scripts\restart_service.bat). Waitress caches bytecode.
8. PUSHING IS THE USER'S CALL. Do not run git push in background scripts.

VERIFY BEFORE YOU TRUST ANY OF IT
  .\venv\Scripts\python.exe -m pytest tests\test_backup_restore.py -v
  cd web; npm test -- --run; npm run build
```

---

## 1. What was completed in this session

1. **Phase 3 Critical Blocker Cleared:** The largest unmitigated project risk (absence of an automated database backup, verified restore drill, and defined rollback window) was resolved in full.
2. **Crash-Safe Online Backup Service ([`app/services/backup_service.py`](file:///e:/MediaServer/app/services/backup_service.py)):**
   - Pure Python standard library implementation utilizing SQLite's Online Backup API.
   - Captures all committed WAL frames page-by-page without blocking concurrent HTTP readers or writers.
   - Emits companion cryptographic manifests (`media_backup_<timestamp>_<label>.json`) recording SHA-256 hashes, byte sizes, schema version, and exact per-table row counts.
   - Retention pruning (`prune_backups()`) retaining the $N$ newest snapshots and pruning stale backups and manifests.
3. **Atomic Database Restoration Engine:**
   - Pre-restoration integrity validation (`verify_backup()`) guarding against corrupt or truncated files.
   - Pre-restore safety rollback points automatically captured before touching the active database.
   - Cleans up stale `media.db-wal` and `media.db-shm` sidecars on Windows, eliminating disk image malformed replay bugs.
   - Atomic staging replacement and post-restoration WAL reinstatement.
4. **CLI Utilities & Automation Scripts:**
   - [`scripts/backup_database.py`](file:///e:/MediaServer/scripts/backup_database.py) — CLI with `--label`, `--keep`, `--json`, and `--no-verify`.
   - [`scripts/restore_database.py`](file:///e:/MediaServer/scripts/restore_database.py) — CLI with `--backup latest`, `--force`, `--no-rollback`, and `--json`.
   - [`scripts/backup_database.bat`](file:///e:/MediaServer/scripts/backup_database.bat) — Windows Task Scheduler batch wrapper.
   - Added `BACKUP_DIR` to [`app/config.py`](file:///e:/MediaServer/app/config.py) and added `backups/` to [`.gitignore`](file:///e:/MediaServer/.gitignore).
5. **Master Disaster Runbook:**
   - Authored [`docs/BACKUP_AND_RESTORE.md`](file:///e:/MediaServer/docs/BACKUP_AND_RESTORE.md) detailing WAL crash safety, CLI reference, Windows Task Scheduler daily backup recipe, and emergency disaster recovery procedures.
   - Defined the Phase 3 PostgreSQL point of no return and $\le 30$-second rollback procedure.
6. **Integration Test Suite & Live Host Verification:**
   - Added [`tests/test_backup_restore.py`](file:///e:/MediaServer/tests/test_backup_restore.py) with 8 comprehensive integration tests passing 100%.
   - Created live baseline backup (`media_backup_20261014_160426_pre-migration-baseline.db`, 516,096 bytes, 852 rows across 11 tables).
   - Executed live dry-run restore drill, proving 100% integrity and table row count parity.

---

## 2. Next steps for the incoming agent

1. **Option B: Production Concurrency Tuning & Remote Streaming Benchmarks ([`AGENTS.md`](file:///e:/MediaServer/AGENTS.md) §4 Priority #1):**
   - Benchmark Waitress worker/thread pools (currently 16 threads in NSSM service) against remote playback latency, Cloudflare tunnel limits, and concurrent client playback.
2. **Option C: Frontend Debt — Refactor `ManagePage.tsx` into Modular Components:**
   - Route bare `fetch()` calls in `ManagePage.tsx` through typed API client with request deadlines (`DEFAULT_TIMEOUT_MS = 20_000`).
   - Extract `StoragePoolHud.tsx`, `RetentionSettingsCard.tsx`, and `ManageInventoryTable.tsx`.
3. **Option D: Resume Phase 3 (PostgreSQL Migration Verification):**
   - With the backup and recovery gate now passed, proceed to spin up/connect a PostgreSQL instance and run `tests/integration/test_postgres_migrations.py`.
