# Session Handoff: 2026-10-16 00:40 IST
**Agent**: opencode
**Topic**: Catalog Reconciliation & USB-Dropout Service Watchdog
**Commits Described**: (this session — see `git log` after commit)

---

## 1. Executive Summary
1. **Outage diagnosed**: `media.anisparvez.in` 502 — `MediaServer`
   (Flask `:8000`), `MediaServerRust` (`:8001`) and PostgreSQL all
   Stopped. Root cause is structural: server lives on USB `E:` and every
   service binary does too (`nssm.exe`, PG bins + `pgdata`); only
   Cloudflared (C:) survived. USB paging error + `E:` re-enumeration in
   System log; PG crash-recovery traces. Restored all three (two elevated
   restarts with user UAC approval); public site 200.
2. **Catalog reconciled**: SQLite 36/36 valid on disk (truth); PG had 6
   stale rows (3 renames, 1 duplicate, 2 orphans + 1 orphaned progress
   row). One-transaction fix with JSON backup; now 36/36 identical, 0
   missing. `cargo test` green (61/61), zero post-suite artifacts.
3. **Watchdog delivered**: `MediaServerWatchdog` scheduled task
   (`awais\anis7`, highest, every 5 min) running
   `scripts/service_watchdog.ps1` (PG -> Rust -> Flask, E:-absent is a
   logged no-op). Live failover drill PASSED.
4. **Two traps fixed**: non-ASCII (em-dash) kills PS 5.1 scripts — repo
   `.ps1` must stay ASCII; repetition on AtLogOn triggers never fires —
   use Once+Repetition heartbeat.

## 2. Active Services & Ports
- **MediaServer** (Waitress/Flask): `:8000` Running (Automatic)
- **MediaServerRust** (Axum): `:8001` Running (Automatic)
- **PostgreSQL 18.4** (`E:\pgdata`): `:5432` running (pg_ctl-managed)
- **Cloudflared**: Running, `media.anisparvez.in` 200
- **MediaServerWatchdog**: Ready, 5-min heartbeat, log
  `C:\MediaServerLogs\watchdog.log`

## 3. Key Files (this session)
- `scripts/service_watchdog.ps1` (new)
- `scripts/install_watchdog.ps1` + `scripts/install_watchdog.bat` (new)
- `docs/SERVICE_WATCHDOG.md` (new)
- `docs/PROJECT_STATUS.md` (recent-work entry)
- `AGENTS.md` (Windows watchdog bullet)
- PG backup (not in repo):
  `C:\Users\anis7\AppData\Local\Temp\opencode\pg_recon_backup.json`

## 4. Paste-ready prompt
```text
Continue work on Anis' Home Media Server at E:\MediaServer.

STATE
- Branch feat/rust-api-foundation (watchdog+recon committed, NOT pushed).
- Services: MediaServer :8000 Running, MediaServerRust :8001 Running,
  PostgreSQL :5432 running, Cloudflared Running, site 200.
  MediaServerWatchdog task Ready, 5-min heartbeat, log
  C:\MediaServerLogs\watchdog.log.
- Catalog: SQLite and PG at 36/36 parity, 0 missing on disk.
- Rust suite: 61/61 green post-reconciliation.

NEXT OBJECTIVE
- Phase 6 slice 1: transcode job model + queue ownership in Rust
  (persistent job records, single-scheduler claim/lease,
  /api/transcode-status reading Rust-owned state). No FFmpeg yet.
```
