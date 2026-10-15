# Walkthrough: Catalog Reconciliation & USB-Dropout Service Watchdog

**Date:** 2026-10-16 IST
**Branch:** `feat/rust-api-foundation`
**Status:** Delivered & verified live (failover drill passed)

---

## 1. Why this happened

The server lives on `E:` (USB removable, label `iamroot`), but every
service binary lives on it too: `E:\MediaServer\bin\nssm.exe` (both NSSM
services), `E:\postgres\pgsql\bin` + `E:\pgdata` (PostgreSQL). Only
Cloudflared lives on `C:` — which is why the tunnel stayed up returning
502 while everything behind it was dead.

Evidence found during diagnosis:

- `MediaServer` (Flask `:8000`), `MediaServerRust` (`:8001`) and
  PostgreSQL all `Stopped`; PG's log showed an interrupted shutdown with
  crash recovery; System log showed a USB-disk paging error and an `E:`
  re-enumeration the same day.
- NSSM cannot self-heal this: `nssm.exe` itself is on the missing volume,
  and SCM only retries a failed start a few times at failure time — it
  never polls "is the exe back yet".

## 2. Catalog reconciliation (PG `media_server` vs SQLite `media.db`)

Flask (`:8000`) served 36 titles, Rust (`:8001`) 39. Disk audit showed
SQLite 36/36 valid; PG had 6 stale rows:

| Rows | Cause | Fix |
|---|---|---|
| 3 bare keys (28 Days, Hail Mary, Oak Street) | files moved into `subdir/file` layout after PG migration | `UPDATE filename` to on-disk key |
| 1 bare key (28 Weeks) | duplicate of existing good subdir key | `DELETE` |
| Odyssey, WALL-E | files gone everywhere | `DELETE` (+1 orphaned WALL-E progress row, per user approval) |

Applied in one transaction after a JSON backup of all affected rows
(6 movies + 1 progress). Result: **36/36, byte-identical sets, 0 missing
on disk**; `cargo test` re-run green (61/61) with zero post-suite
artifacts. SQLite untouched.

## 3. Watchdog (`MediaServerWatchdog` scheduled task)

| File | Purpose |
|---|---|
| `scripts/service_watchdog.ps1` | The check: E: present? PG up (`pg_ctl status`, else `start`)? `MediaServerRust` then `MediaServer` Running (else `Start-Service`)? Logs to `C:\MediaServerLogs\watchdog.log` (C: survives E: absence). `-DryRun` supported. Idempotent. |
| `scripts/install_watchdog.ps1` / `.bat` | Registration: principal `awais\anis7`, highest privileges, once-plus-repeat heartbeat every 5 min for 10 years, file-logged with visible result. |

Order matters: PG first (Rust's pool connects on first try), then Rust,
then Flask. If `E:` is absent the script logs `SKIP` and touches
nothing.

Two traps found while building it (both now fixed):

1. **PowerShell 5.1 is not UTF-8.** Em-dashes in the scripts parsed as
   garbage and killed execution. All repo `.ps1` must stay pure ASCII.
2. **Repetition on an AtLogOn trigger never schedules** (`NextRunTime`
   stays empty — only manual runs fire). The heartbeat must be an
   **Once trigger + RepetitionInterval**; verified `NextRunTime`
   advances every 5 min.

## 4. Failover drill (live, passed)

Stopped `MediaServerRust` (`:8001` refusing). Next tick detected
`Stopped`, restarted it, `:8001` 200 on health + movies. Full log in
`C:\MediaServerLogs\watchdog.log`.

## 5. Known limits

- Task principal is Interactive: it runs while logged on. Boot without
  logon still relies on SCM autostart (works when E: is present).
- Mid-run E: drops still kill in-flight transcodes/progress writes; the
  watchdog restores service liveness, not interrupted jobs.
- Longer-term hardening: move `nssm.exe`/PG binaries to C: so the
  watchdog itself survives the drop; disable USB selective suspend.
