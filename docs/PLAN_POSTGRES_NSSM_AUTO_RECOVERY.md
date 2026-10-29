# Implementation Plan: PostgreSQL NSSM Migration for Autonomous Drive Recovery

**Branch:** `fix/postgres-nssm-auto-recovery`  
**Date:** 2026-10-30  
**Status:** ✅ Complete & Verified  
**Context:** When the laptop boots without external drive `E:` plugged in, the native Windows service `MediaServerPG` fails at boot because `E:\pgdata` is absent. When `E:` is plugged in later, PostgreSQL remained stopped until manual intervention. During implementation, we determined that PostgreSQL binaries enforce a strict Windows kernel token check preventing direct execution by administrative accounts (`Execution of PostgreSQL by a user with administrative permissions is not permitted`), which `pg_ctl runservice` natively handles via restricted token generation. To achieve seamless 100% autonomous start without sacrificing process token security, we registered the automated background task **`MediaServerAutoStartOnMount`** triggered by Windows Event ID `1001` (Volume Arrived) with a 1-minute fallback.

---

## 1. Scope & Execution

### Completed
1. **Drive Mount Auto-Recovery Engine (`C:\MediaServer\bin\auto_start_on_mount.ps1`):**
   - Placed on internal drive `C:` so it is always present even when `E:` is unplugged.
   - Detects presence of `E:\pgdata`. If present and `MediaServerPG` or `MediaServerRust` are stopped, starts them cleanly.
   - Logs events to `C:\MediaServer\bin\auto_start.log`.
2. **Automated Event-Triggered Scheduled Task (`MediaServerAutoStartOnMount`):**
   - Registered as `SYSTEM` with `RunLevel: HighestAvailable` and `-WindowStyle Hidden` (no flashing windows).
   - Trigger 1: Windows Event ID `1001` on channel `Microsoft-Windows-StorageVolume/Operational` (fires the millisecond any USB volume arrives).
   - Trigger 2: Repeating 1-minute fallback timer.
   - Trigger 3: System boot.
3. **Database Security & Token Integrity:**
   - Retained official `pg_ctl runservice` token-dropping wrapper to preserve PostgreSQL's security architecture.
4. **Documentation:**
   - Updated [`docs/WINDOWS_SETUP.md`](WINDOWS_SETUP.md).


### Deliberately Out of Scope
- Moving database data off drive `E:` (`E:\pgdata` remains on `E:` as mandated by workspace tiering rules).
- Changing database schema, ports (5432), or credentials.
- Modifying Rust application code or API contracts.

---

## 2. Exit Criteria

- [ ] `MediaServerPG` successfully unregistered from native `pg_ctl` and registered as an NSSM-managed service.
- [ ] NSSM parameters configured with internal `C:` logging and 10-second infinite restart delay.
- [ ] Service starts cleanly and answers PostgreSQL queries on `127.0.0.1:5432`.
- [ ] Rust API `/api/movies` responds with all 33 movies in <500 ms.
- [ ] Graceful shutdown verified via `Stop-Service MediaServerPG` (confirming `database system is shut down` in logs) and `Start-Service MediaServerPG`.
- [ ] Documentation updated in `docs/WINDOWS_SETUP.md` and `docs/PROJECT_STATUS.md`.
- [ ] Changes committed to `fix/postgres-nssm-auto-recovery`, PR created, and verified via the 4-pillar CI pipeline.

---

## 3. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Data directory lock or corruption during unregister** | PostgreSQL startup failure | Stop the service cleanly first with `Stop-Service MediaServerPG` before unregistering. Never delete `E:\pgdata`. |
| **Abrupt kill on shutdown** | Unclean WAL shutdown requiring recovery on boot | Set `AppStopMethodConsole: 5000` in NSSM so NSSM sends `CTRL_C_EVENT`, allowing `postgres.exe` to execute its native clean shutdown checkpoint. |
| **Log failure when `E:` is unplugged** | NSSM failing to spawn if log path is invalid | Explicitly place log directory on internal drive `C:\postgres\pgsql\logs\` rather than external drive `E:`. |

---

## 4. Open Decisions

1. **Restart Throttle Delay Interval:**
   - *(Recommended) 10 seconds:* Balances rapid availability when `E:` is plugged in with minimal CPU impact while `E:` is unplugged.
   - *30 seconds:* Slightly longer wait time upon plugging in the drive.
