# Walkthrough: Catalog Reconciliation & USB-Dropout Service Resilience

**Date:** 2026-10-16 IST
**Branch:** `feat/rust-api-foundation`
**Status:** Delivered & verified live (failover drill passed)

> **Status update — the watchdog is NOT installed (user decision, 2026-10-16).**
> After NSSM and PostgreSQL were rehomed to `C:`, the watchdog's value
> collapsed and it was unregistered
> (`scripts/uninstall_watchdog.ps1`). It ran an interactive PowerShell
> process every 5 minutes, which flashed a console window on the desktop -
> unacceptable for a background safety net.
>
> The scripts are **retained on purpose**: `scripts/install_watchdog.ps1`
> re-arms it on demand, and §3 records the two bugs that must not be
> reintroduced if it is ever brought back.
>
> **What now covers service loss without the watchdog:** NSSM restarts
> Flask/Rust within ~5s of a crash; `MediaServerPG` has restart-x3 recovery
> actions; the "NSSM itself missing" failure is gone with the C: move.
>
> **Accepted gap (deliberate):** recovery actions are finite. If all three
> attempts fail, or the host boots with `E:` unplugged so no service can
> start, the services stay Stopped until someone runs
> `scripts/restart_service.bat`. That was the original outage, so this is a
> real trade, not an oversight.

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
| `scripts/service_watchdog.ps1` | The check: E: present? PG up (TCP 5432)? `MediaServerRust` then `MediaServer` Running (else `Start-Service`)? Logs to `C:\MediaServerLogs\watchdog.log` (C: survives E: absence). `-DryRun` supported. Idempotent. |
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
3. **`pg_ctl status` reports a healthy cluster as stopped.** Once the
   postmaster runs as `NetworkService`, `pg_ctl status` executed by the
   logged-on admin account cannot open the process and prints `no server
   running` (exit 3) against a cluster that is serving queries. The same
   false negative appeared from the stale `postmaster.pid` left by the
   C: move. A watchdog built on that probe would have re-issued a start on
   every single tick and logged a false failure forever, while the real
   value it was added for went unnoticed. The probe is now a **TCP
   connect to 127.0.0.1:5432**; the service name is used for the start
   decision. Verified: PID 21412 serving, `select count(*) from movies`
   returns 36, and the probe agrees.

## 4. Failover drill (live, passed, then retired)

Stopped `MediaServerRust` (`:8001` refusing). The next tick detected
`Stopped`, restarted it, and `:8001` returned 200 on health and movies - so
the mechanism was proven correct, not merely assumed. It was then removed by
user decision (see the status banner) once NSSM's own restart covered the
crash case, because its 5-minute interactive run flashed a console window
on the desktop. Log history preserved at `C:\MediaServerLogs\watchdog.log`.

## 5. C:-resident hosting (2026-10-16 follow-up)

NSSM and PostgreSQL no longer depend on `E:` to *start*:

- `C:\MediaServer\bin\nssm.exe` hosts `MediaServer` + `MediaServerRust`
  (`scripts/move_nssm_to_c.ps1`; `E:` copy kept as fallback). The
  watchdog now survives an `E:` drop and NSSM keeps retrying the `E:`-bound
  app until the volume returns.
- `C:\postgres` holds the PG binaries; `E:\pgdata` keeps the data.
  `MediaServerPG` runs as `NT AUTHORITY\NetworkService` (postmaster
  refuses admin/LocalSystem) with full control on the data dir
  (`scripts/move_pg_to_c.ps1`), Automatic start + restart-x3 recovery.
  `start/stop_postgres.bat` and the watchdog prefer `C:` with `E:` fallback;
  the watchdog uses the service when registered.
- Remaining gap is unchanged: at boot without `E:`, SCM start fails and
  the logged-on watchdog starts PG once the volume appears.

## 6. Known limits

- Task principal is Interactive: it runs while logged on. Boot without
  logon still relies on SCM autostart (works when E: is present).
- Mid-run E: drops still kill in-flight transcodes/progress writes; the
  watchdog restores service liveness, not interrupted jobs.
- ~~Longer-term hardening: move `nssm.exe`/PG binaries to C:~~ Done (§5).
  Remaining: disable USB selective suspend.

- Task principal is Interactive: it runs while logged on. Boot without
  logon still relies on SCM autostart (works when E: is present).
- Mid-run E: drops still kill in-flight transcodes/progress writes; the
  watchdog restores service liveness, not interrupted jobs.
- Longer-term hardening: move `nssm.exe`/PG binaries to C: so the
  watchdog itself survives the drop; disable USB selective suspend.
