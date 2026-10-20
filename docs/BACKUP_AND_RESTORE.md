# Database Backup, Recovery & Disaster Runbook

| Metadata | Details |
|---|---|
| **Authoritative Document** | Operational Runbook & Disaster Recovery Gate |
| **System** | Anis' Home Media Server (`E:\MediaServer`) |
| **Database Engine** | **PostgreSQL 18.4** |
| **Primary Database** | `media_server` — data directory `E:\pgdata`, server binaries `C:\postgres` |
| **Default Backup Store** | `E:\MediaServer\backups\postgres\` (gitignored) |
| **Backup Tool** | [`scripts/backup_postgres.ps1`](../scripts/backup_postgres.ps1) → `pg_dump -Fc` |
| **Restore Tool** | [`scripts/restore_postgres.ps1`](../scripts/restore_postgres.ps1) → `pg_restore` |
| **Live Database Size** | ~10 MB (13 tables) |
| **Last Verified** | **2026-10-20** — full backup → restore → restart drill, all row counts matched |

> **This runbook replaces the SQLite-era document.** The previous version documented
> `app/services/backup_service.py`, `scripts/backup_database.py` and `scripts/restore_database.py`
> — all of which were **decommissioned** with the Flask backend in Slice 7E (2026-10-18). The
> SQLite failure modes it warned about no longer apply; a new set does. See
> [§8](#8-historical-the-sqlite-era-retired) for the retired material.

---

## 1. What the Database Is Now

| Property | Value |
|---|---|
| Engine | PostgreSQL 18.4 (`MediaServerPG` Windows Service, `NetworkService` account) |
| Database | `media_server` |
| Connection | `postgresql://postgres:postgres@127.0.0.1:5432/media_server` |
| Data directory | `E:\pgdata` |
| Server binaries | `C:\postgres\pgsql\bin` (`psql`, `pg_dump`, `pg_restore`) |
| Service | `MediaServerPG` — automatic, restart-x3 recovery actions |
| Tables (13) | `movies`, `progress`, `users`, `sessions`, `auth_tokens`, `settings`, `devices`, `device_watch_history`, `device_pair_sessions`, `oauth_attempts`, `ip_cache`, `transcode_jobs`, `schema_migrations` |
| Size | ~10 MB |

The Rust server owns the schema it needs. `db::ensure_schema()` runs on **every pool creation** and
creates its tables with `CREATE TABLE IF NOT EXISTS`, so a fresh database self-provisions and a
restored older dump is still serviceable — see [§5](#5-schema-and-ensure_schema).

---

## 2. Backup

### 2.1 Taking one

```powershell
# Default: media_server -> E:\MediaServer\backups\postgres\, keep the newest 7
E:\MediaServer\scripts\backup_postgres.bat

# Or, from PowerShell, with explicit parameters:
E:\MediaServer\scripts\backup_postgres.ps1 -Database media_server -Keep 7

# Verify a dump into a scratch database instead of the live one (safe):
E:\MediaServer\scripts\restore_postgres.ps1 -TargetDatabase media_server_verify
```

The script locates `pg_dump.exe` (preferring `C:\postgres\pgsql\bin`), runs:

```text
pg_dump -h 127.0.0.1 -p 5432 -U postgres -d media_server -F c -b -v -f <dest>
```

| Flag | Effect | Why it matters |
|---|---|---|
| `-F c` | **Custom archive format** | Compressed (gzip), and restorable selectively or in parallel with `pg_restore -j`. |
| `-b` | Include large objects | Completeness. |
| `-v` | Verbose | The archive is self-describing — `pg_restore --list` shows every object. |

### 2.2 Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Database` | `media_server` | Database to dump. |
| `-User` | `postgres` | Connecting role. |
| `-DbHost` / `-Port` | `127.0.0.1` / `5432` | Server address. |
| `-DestDir` | `E:\MediaServer\backups\postgres` | Where the archive is written. |
| `-Keep` | `7` | Retention. **Prunes the oldest beyond this count. `0` disables pruning entirely** (the guard is `if ($Keep -gt 0)`), so `-Keep 0` means *keep everything*, not *keep none*. |

### 2.3 Output

```text
E:\MediaServer\backups\postgres\media_server_<yyyyMMdd_HHmmss>.dump
```

Each archive records its own provenance in its header:

```text
;
; Archive created at 2026-10-20 11:12:38
;     dbname: media_server
;     TOC Entries: 73
;     Compression: gzip
;     Format: CUSTOM
;     Dumped from database version: 18.4
;     Dumped by pg_dump version: 18.4
```

### 2.4 Rotation

The script prunes the oldest archives beyond `-Keep` on each run. Note the default of 7 daily
backups covers **one week** — with no scheduling in place (see [§7](#7-known-gaps)) the store will
not actually roll over until backups are being taken regularly.

---

## 3. Restore

### 3.1 The procedure

> **Stop the server first.** The Rust server holds a pooled connection set against the objects
> that `--clean` is about to drop and recreate. Restoring underneath a running server is how you
> get a half-restored database and a service that looks healthy but is serving stale handles.

```powershell
# 1. Stop the service
Stop-Service MediaServerRust -Force

# 2. Restore. Without -Confirm this is a dry run that only inspects the archive.
E:\MediaServer\scripts\restore_postgres.ps1 -Confirm

# 3. Start the service and check it
Start-Service MediaServerRust
Invoke-WebRequest http://127.0.0.1:8000/health -UseBasicParsing
```

### 3.2 What the restore tool does

| Step | Behaviour |
|---|---|
| **1. Verify** | Runs `pg_restore --list` on the archive. A corrupt or non-custom-format file fails here, **before** anything is touched. Reports the TOC entry count. |
| **2. Rollback point** | Takes a fresh `pg_dump` of the **current** database first, to `media_server_prerestore_<ts>.dump`. If the restore turns out to be the wrong dump, the previous state is still on disk. **Refuses to proceed if the rollback point cannot be created.** |
| **3. Restore** | `pg_restore --clean --if-exists --no-owner --no-privileges`. `--clean` drops existing objects before recreating them; `--if-exists` tolerates objects that are not there. |
| **4. Verify** | Reads back row counts from the restored database and reports them per table. |

### 3.3 Options

| Parameter | Default | Description |
|---|---|---|
| `-DumpFile` | newest `media_server_*.dump` in `-DestDir` | Archive to restore. |
| `-TargetDatabase` | *(none — restore over the live database)* | Restore into a different database instead. This is the **safe way to validate a dump**. |
| `-NoRollbackPoint` | off | Skip the pre-restore dump. Only sensible for a scratch target. |
| `-Confirm` | off | **Required to actually restore.** Without it the script only inspects and prints what it would do. |

### 3.4 Verifying a dump before trusting it

```powershell
E:\MediaServer\scripts\restore_postgres.ps1 -TargetDatabase media_server_verify -Confirm
```

This restores into a throwaway database and leaves the live one untouched. Drop the scratch
database afterwards:

```powershell
& C:\postgres\pgsql\bin\psql.exe -h 127.0.0.1 -U postgres -d postgres -c "DROP DATABASE media_server_verify;"
```

### 3.5 The manual equivalent

If the script is unavailable, this is the same operation:

```powershell
$env:PGPASSWORD = "postgres"
& C:\postgres\pgsql\bin\psql.exe -h 127.0.0.1 -U postgres -d postgres -c "CREATE DATABASE media_server_restore;"
& C:\postgres\pgsql\bin\pg_restore.exe -h 127.0.0.1 -U postgres -d media_server_restore `
    --clean --if-exists --no-owner --no-privileges `
    E:\MediaServer\backups\postgres\media_server_<timestamp>.dump
```

---

## 4. Failure Modes

The SQLite-era hazards **no longer apply**. These are the PostgreSQL ones.

| Hazard | What goes wrong | Mitigation |
|---|---|---|
| **Restoring under a running server** | The app's pooled connections survive the objects being dropped, so it serves stale handles or errors on the next query. | Stop `MediaServerRust` first. Always. |
| **`--clean` without the right privileges** | `pg_restore` aborts partway, leaving the database partially restored — and the *old* objects for the ones it did not reach. | The connecting role must own the objects. The restore tool uses `--no-owner --no-privileges` so ownership is not reapplied. |
| **Restoring a dump from before a schema change** | The restored database is missing columns or tables the current code expects. | **Not a problem here.** `ensure_schema()` runs at pool creation and creates anything missing — see [§5](#5-schema-and-ensure_schema). |
| **Restoring the wrong dump** | You overwrite good data with an old snapshot. | The restore tool takes a rollback point first, and refuses to proceed if it cannot take one. |
| **The rollback point is not a backup** | It lives in the same directory and the same disk as the archives. | It is a safety net for a bad restore, not a disaster-recovery copy. See [§7](#7-known-gaps). |
| **`-Keep 0` read as "keep none"** | It actually disables pruning, so the store grows without bound. | The parameter is documented as such in [§2.2](#22-parameters). Use a positive number. |
| **Backups on the same volume as the data** | `E:\pgdata` and `E:\MediaServer\backups` are both on `E:`. A volume failure takes both. | See [§7](#7-known-gaps). Off-host copies are the real fix. |

---

## 5. Schema and `ensure_schema`

`db::ensure_schema()` in `rust/src/db.rs` runs on **every pool creation** — production, test, and
after a restore. It applies its DDL inside a transaction guarded by
`pg_advisory_xact_lock(7429184)`, so concurrent server starts serialise rather than collide.

It creates, with `CREATE TABLE IF NOT EXISTS`:

`transcode_jobs`, `settings`, `users`, `auth_tokens`, `oauth_attempts`, `sessions`,
`device_pair_sessions`, `movies`, `progress`, `devices`, `device_watch_history`, `ip_cache`

**Practical consequences:**

- A dump taken **before** the `movies`/`progress`/`devices` tables were added is still safe to
  restore. Restart the server and the missing tables appear. The *rows* are not recovered, but the
  schema is.
- A dump taken **before** a column was added to an existing table is **not** repaired.
  `CREATE TABLE IF NOT EXISTS` is a no-op on an existing table, so a missing column stays missing.
  Schema *changes* to existing tables need their own migration.
- Restoring a dump does **not** require the service to be running first — but the service must be
  restarted afterwards to pick up the restored state, and it will apply `ensure_schema()` on boot.

---

## 6. Verification Drill

The procedure below was executed on **2026-10-20** against the live `media_server` database. It is
the drill to repeat after any change to the backup or restore tooling.

```powershell
# 1. Back up
E:\MediaServer\scripts\backup_postgres.ps1

# 2. Record the source row counts
& C:\postgres\pgsql\bin\psql.exe -h 127.0.0.1 -U postgres -d media_server -A -t `
    -c "SELECT count(*) FROM movies;"

# 3. Stop the service
Stop-Service MediaServerRust -Force

# 4. Restore over the live database (takes a rollback point automatically)
E:\MediaServer\scripts\restore_postgres.ps1 -Confirm

# 5. Compare, restart, and check
Start-Service MediaServerRust
Invoke-WebRequest http://127.0.0.1:8000/health -UseBasicParsing
```

**Result of the 2026-10-20 drill:**

| Check | Result |
|---|---|
| Archive verification | 73 TOC entries, readable |
| Rollback point | `media_server_prerestore_20261020_111412.dump` written automatically |
| `movies` | 33 → 33 |
| `users` | 3 → 3 |
| `sessions` | 13 → 13 |
| `progress` | 8 → 8 |
| `devices` | 393 → 393 |
| `settings` | 3 → 3 |
| `auth_tokens` | 21 → 21 |
| Public tables | 13 → 13 |
| Service health after restart | `200 {"engine":"rust","status":"healthy"}` |
| Public API after restart | `200` on `/api/movies` |

---

## 7. Known Gaps

Honest list of what this runbook does **not** yet solve.

1. **No scheduled backup.** Nothing on this host runs `backup_postgres.ps1` automatically — there
   is no Scheduled Task referencing it. The archives in the store were taken by hand. **Until a
   daily task exists, a restore is only as good as the last manual run.** A Scheduled Task
   invoking `scripts\backup_postgres.bat` daily would close this.
2. **Backups live beside the data.** `E:\pgdata` and `E:\MediaServer\backups` are both on `E:`. A
   volume failure takes the database *and* the backups together. Off-host or off-volume copies are
   the actual fix.
3. **The restore tool is not itself backed up in git history.** It is new as of 2026-10-20; the
   previous restore path was a Python script that no longer exists.
4. **No integrity verification of the archive beyond readability.** `pg_restore --list` proves the
   archive parses; it does not prove every row is recoverable. A full restore into a scratch
   database ([§3.4](#34-verifying-a-dump-before-trusting-it)) is the real check.
5. **No `pg_dumpall` for the cluster.** The `postgres` maintenance database and the role
   definitions are not backed up, only the `media_server` database. Cluster-level recovery is out
   of scope here.

---

## 8. Historical: the SQLite Era (Retired)

The previous version of this document described a **SQLite 3 (WAL mode)** backup system. It is
fully retired. Retained here so the reasoning is not lost:

- **What it did:** zero-lock online backup via SQLite's `source_conn.backup(dest_conn, pages=100)`
  API, with a companion SHA-256 manifest recording per-table row counts, and a two-phase restore
  that unlinked stale `-wal`/`-shm` sidecars before an atomic promote.
- **Why it was retired:** the whole backend moved to PostgreSQL 18.4 in Phase 3, and the Flask
  service that owned it was decommissioned in Slice 7E. `app/services/backup_service.py`,
  `scripts/backup_database.py` and `scripts/restore_database.py` no longer exist.
- **The failure mode it warned about** — restoring a raw `.db` over an existing path without
  clearing the `-wal` and `-shm` sidecars, causing SQLite to replay stale write-ahead logs over the
  new file and corrupt it — **cannot occur in PostgreSQL**. The equivalent hazards are listed in
  [§4](#4-failure-modes).
- **Artifacts still on disk** from that era, kept as evidence of the migration:
  `backups\media_backup_20261014_160426_pre-migration-baseline.db` (+ its `-wal`, `-shm` and
  `.json` manifest) and the two `backups\migration_report_*.json` files. They are **not** restorable
  into the current schema and must not be used for recovery.

---

## 9. Related

- [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md) — project-wide status
- [`docs/WINDOWS_SETUP.md`](WINDOWS_SETUP.md) — service installation and operations
- [`docs/DEVELOPMENT_STATUS.md`](DEVELOPMENT_STATUS.md) — development environment and testing
- [`AGENTS.md`](../AGENTS.md) §9 — the database test isolation and teardown guardrail
