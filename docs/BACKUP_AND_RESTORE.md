# Database Backup, Recovery & Disaster Runbook

| Metadata | Details |
|---|---|
| **Authoritative Document** | Operational Runbook & Phase 3 Rollback Gate |
| **System** | Anis' Home Media Server (`E:\MediaServer`) |
| **Database Engine** | SQLite 3 (WAL journal mode) $\rightarrow$ PostgreSQL target |
| **Primary Database** | `E:\MediaServer\media.db` (SSD Tier) |
| **Default Backup Store** | `E:\MediaServer\backups\` (gitignored) |
| **Last Verified** | October 14, 2026 (Live Recovery Drill Passed) |

---

## 1. Architecture & Crash Safety

The Media Server uses SQLite in **Write-Ahead Logging (WAL)** mode (`PRAGMA journal_mode=WAL`). Under WAL mode, active transactions and dirty pages accumulate in `media.db-wal` before being checkpointed back to `media.db`.

### Why Naive File Copies Fail
- Copying `media.db` directly while Waitress or background workers are running captures a **torn, inconsistent snapshot** without uncheckpointed WAL frames.
- Restoring a raw `.db` over an existing path without clearing `media.db-wal` and `media.db-shm` causes SQLite to replay stale write-ahead logs over the new database, resulting in fatal corruption (`sqlite3.DatabaseError: database disk image is malformed`).

### The Online Backup Architecture (`app/services/backup_service.py`)
1. **Zero-Lock Online Backup:** Uses SQLite's native Online Backup API (`source_conn.backup(dest_conn, pages=100)`). Transfers data page-by-page without blocking concurrent HTTP readers or writers, incorporating all committed WAL frames directly into a clean, defragmented single-file database.
2. **Companion Cryptographic Manifest:** Generates an atomic `media_backup_<timestamp>_<label>.json` manifest recording the SHA-256 hash, file size, schema migration version, and exact row counts for every table (`movies`, `progress`, `devices`, `device_watch_history`, `settings`, `users`, `auth_tokens`, etc.).
3. **Atomic Two-Phase Restore:** Validates backup integrity and checksums *before* touching the target. Automatically captures a safety rollback point of the current database, unlinks stale `-wal` and `-shm` sidecars, stages the backup, and atomically promotes it with `replace()`.
4. **Post-Restore Integrity Check:** Re-initializes the database with `PRAGMA integrity_check` and ensures `PRAGMA journal_mode=WAL` is active.

```text
┌────────────────────────┐      con.backup(pages=100)      ┌────────────────────────┐
│ E:\MediaServer\media.db│ ──────────────────────────────> │   Temporary Staging    │
│ (Active WAL Mode)      │                                 │ .tmp file in backups/  │
└────────────────────────┘                                 └───────────┬────────────┘
                                                                       │ Atomic Promote
                                                                       ▼
                                                           ┌────────────────────────┐
                                                           │ media_backup_*.db      │
                                                           │ + media_backup_*.json  │
                                                           │ (SHA-256 Verified)     │
                                                           └────────────────────────┘
```

---

## 2. CLI Tools & Operational Usage

### 2.1 Creating a Backup

Run the automated backup script from the repository root:

```powershell
.\venv\Scripts\python.exe scripts\backup_database.py --label manual
```

#### CLI Options
| Flag | Default | Description |
|---|---|---|
| `--source <path>` | `E:\MediaServer\media.db` | Custom database to back up |
| `--dest <dir>` | `E:\MediaServer\backups` | Target directory for backup and manifest |
| `--label <text>` | `manual` | Descriptive tag in filename (e.g. `pre-migration`) |
| `--keep <N>` | `7` | Retention policy: retain newest $N$ backups, pruning older snapshots and manifests ($0$ disables pruning) |
| `--no-verify` | `False` | Skip post-backup SQLite integrity verification |
| `--json` | `False` | Output JSON result for programmatic scripts |

#### Example Output
```text
==================================================
  DATABASE BACKUP COMPLETED SUCCESSFULLY
==================================================
  Backup File : media_backup_20261014_160426_pre-migration-baseline.db
  Destination : E:\MediaServer\backups\media_backup_20261014_160426_pre-migration-baseline.db
  Size        : 516,096 bytes
  SHA-256     : f5287598106a2bf8354099722f5067890b2a59331d4b69473fa94518e693097e
  Integrity   : OK
  Total Rows  : 852
  Schema Ver  : 1
==================================================
```

### 2.2 Restoring from a Backup

Restore the database using `scripts/restore_database.py`. You can specify an explicit `.db` file or use `latest`:

```powershell
# Interactive restore from the most recent backup
.\venv\Scripts\python.exe scripts\restore_database.py --backup latest

# Non-interactive forced restore from a specific file
.\venv\Scripts\python.exe scripts\restore_database.py --backup E:\MediaServer\backups\media_backup_20261014_160426_pre-migration-baseline.db --force
```

#### CLI Options
| Flag | Description |
|---|---|
| `--backup <path\|latest>` | Path to `.db` backup file or `latest` to pick the newest in `backups/` |
| `--target <path>` | Target file (defaults to active `E:\MediaServer\media.db`) |
| `--no-rollback` | Skip taking an automatic safety snapshot of the target database before overwriting |
| `--force`, `-f` | Bypass interactive confirmation prompt |
| `--json` | Emit JSON output for automated pipelines |

---

## 3. Automated Daily Backups (Windows Task Scheduler)

A batch file wrapper is provided at [`scripts/backup_database.bat`](file:///e:/MediaServer/scripts/backup_database.bat). To configure a recurring daily backup at 03:00 AM retaining 14 days of history:

1. Open an elevated PowerShell terminal.
2. Register the scheduled task:

```powershell
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c E:\MediaServer\scripts\backup_database.bat" -WorkingDirectory "E:\MediaServer"
$trigger = New-ScheduledTaskTrigger -Daily -At "03:00AM"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "MediaServer_DailyBackup" -Action $action -Trigger $trigger -Settings $settings -User "NT AUTHORITY\SYSTEM"
```

3. To verify or trigger manually:
```powershell
Start-ScheduledTask -TaskName "MediaServer_DailyBackup"
Get-ScheduledTaskInfo -TaskName "MediaServer_DailyBackup"
```

---

## 4. Disaster Recovery & Rollback Runbooks

### Scenario A: Accidental Database Deletion or Corruption

If `media.db` becomes unreadable or corrupt:

1. **Stop the MediaServer persistent service** (elevated):
   ```powershell
   Stop-Service MediaServer
   ```
2. **Restore from the latest verified backup**:
   ```powershell
   .\venv\Scripts\python.exe scripts\restore_database.py --backup latest --force
   ```
3. **Restart the persistent service**:
   ```powershell
   Start-Service MediaServer
   ```
4. **Verify application health**:
   ```powershell
   python scripts\snapshot_live_data.py
   ```

---

### Scenario B: Phase 3 PostgreSQL Migration Rollback Procedure

Before running PostgreSQL schema transfers or point cutovers:

1. **Capture Pre-Migration Baseline:**
   ```powershell
   .\venv\Scripts\python.exe scripts\backup_database.py --label pre-pg-migration --keep 30
   ```
   Note the generated file name (e.g. `media_backup_20261014_160426_pre-pg-migration.db`).

2. **Point of No Return Definition:**
   - **Before Cutover:** SQLite remains the single canonical source of truth. Rollback is instant ($\le 30$ seconds) by restoring the baseline file and restarting the Waitress service.
   - **During Cutover:** New writes (watch progress, device pairing) occur in PostgreSQL.
   - **Emergency Rollback Window:** If PostgreSQL encounters schema locks, connection exhaustion, or query regression within the trial window:
     1. Stop Waitress: `Stop-Service MediaServer`.
     2. Restore SQLite baseline:
        ```powershell
        .\venv\Scripts\python.exe scripts\restore_database.py --backup E:\MediaServer\backups\media_backup_YYYYMMDD_HHMMSS_pre-pg-migration.db --force
        ```
     3. Ensure `MEDIA_SERVER_DATABASE_BACKEND=sqlite` in `.env`.
     4. Restart service: `Start-Service MediaServer`.
     5. Zero HLS cache, transcode state, or raw media is lost because media and HLS caches live on filesystem paths indexed by filename.

---

## 5. Verification & Acceptance Record

- **Test Suite:** [`tests/test_backup_restore.py`](file:///e:/MediaServer/tests/test_backup_restore.py) passes 8/8 tests with 100% coverage:
  - `test_backup_creation_and_manifest`: PASSED
  - `test_verify_backup_tamper_detection`: PASSED
  - `test_restore_database_with_rollback`: PASSED
  - `test_restore_cleans_stale_wal_sidecars`: PASSED
  - `test_prune_backups_retention`: PASSED
  - `test_cli_backup_and_restore`: PASSED
  - `test_list_backups_metadata`: PASSED
  - `test_restore_rejects_unverified_file`: PASSED
- **Live Host Execution:**
  - Verified baseline created at `E:\MediaServer\backups\media_backup_20261014_160426_pre-migration-baseline.db` (516,096 bytes, SHA-256 `f5287598106a...`, 852 rows across 11 tables).
  - Live recovery drill executed against a dry-run target, confirming 100% integrity check (`ok`) and exact row parity (44 movies, 371 devices, 3 settings).
