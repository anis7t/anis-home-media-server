# Implementation Plan — Off-Host Database Backups (Category 5.5)

## 1. Context & Motivation

- **Current State:**
  - Automated PostgreSQL backups run daily at 03:00 via the Windows Scheduled Task `MediaServerBackup`.
  - The script [`scripts/backup_postgres.ps1`](../scripts/backup_postgres.ps1) executes `pg_dump -Fc` on the `media_server` database, writing custom-format compressed archives to `E:\MediaServer\backups\postgres`.
  - Backups are pruned on `E:` with a 7-day retention window for scheduled backups and 3 rollback points.
- **The Core Vulnerability:**
  - Both the active PostgreSQL cluster (`E:\pgdata`) and its backup store (`E:\MediaServer\backups\postgres`) reside on the **exact same physical SSD volume (`E:`)**.
  - If Drive `E:` suffers a hardware crash, file corruption, or filesystem failure, both the live database and all historical backups are destroyed simultaneously.
  - While Drive `D:` (`D:\Flicks`) provides large-capacity storage, no backup replication currently targets it, and no off-host/cloud synchronization hook exists.

---

## 2. Scope & Design

### A. What Changes
1. **[`scripts/backup_postgres.ps1`](../scripts/backup_postgres.ps1):**
   - **Pre-Replication Integrity Verification:** Run `pg_restore --list` immediately upon dump completion. If the archive is corrupted, truncated, or unreadable, fail immediately before touching existing backups or replicating.
   - **Secondary Cross-Volume Mirroring:** Add parameter `$SecondaryDestDir` (defaulting to `D:\Flicks\.backups\postgres`). Atomically replicate the verified dump to `D:` with checksum/size confirmation.
   - **Independent Secondary Retention:** Add parameter `$KeepSecondary` (defaulting to 14 days). Prune old backups on `D:` independently from `E:` so `D:` maintains a longer cold recovery window.
   - **Graceful Fault Tolerance:** Wrap secondary replication in error containment. If Drive `D:` is temporarily full or offline, the primary backup on `E:` is preserved and a prominent warning is logged, preventing scheduled task crashes.
   - **Extensible Post-Backup Hook:** Support `-PostBackupCommand` parameter and `MEDIA_SERVER_POST_BACKUP_CMD` environment variable, enabling seamless chaining with tools like `rclone`, AWS S3 CLI, or external drive sync.
2. **[`scripts/restore_postgres.ps1`](../scripts/restore_postgres.ps1):**
   - **Disaster Recovery Secondary Fallback:** If `DestDir` (`E:\MediaServer\backups\postgres`) is inaccessible or contains no `.dump` archives, automatically fall back to searching `$SecondaryDestDir` (`D:\Flicks\.backups\postgres`), alerting the operator that cold disaster recovery storage is being used.
3. **[`rust/src/scanner/engine.rs`](../rust/src/scanner/engine.rs):**
   - Add `.backups` to the directory ignore filter in `ScannerEngine::discover_video_files` to ensure scanner crawls under `D:\Flicks` never descend into `.backups`.
4. **[`docs/BACKUP_AND_RESTORE.md`](../docs/BACKUP_AND_RESTORE.md):**
   - Document dual-drive storage tiering for backups (`E:` primary 7 days, `D:` secondary 14 days), integrity checks, and disaster recovery procedures.

### B. What Deliberately Does Not Change
- The Windows Scheduled Task `MediaServerBackup` at 03:00 runs `scripts/run_backup_task.bat`, which calls `scripts/backup_postgres.ps1` with default arguments. No Scheduled Task recreation is needed.
- `pg_dump -Fc` format and PostgreSQL 18.4 database tables remain 100% compatible.
- Zero disruption to the live Rust Axum backend or connected clients.

---

## 3. Exit Criteria

1. Running `powershell scripts/backup_postgres.ps1` produces a valid `.dump` in `E:\MediaServer\backups\postgres` AND mirrors it to `D:\Flicks\.backups\postgres`.
2. Both dump files pass `pg_restore --list` verification with matching byte sizes and TOC counts.
3. Pruning independently respects 7-day retention on `E:` and 14-day retention on `D:`.
4. `scripts/restore_postgres.ps1` dry run resolves dumps from primary `E:`, and when tested against an empty primary directory, automatically resolves from secondary `D:`.
5. Scanner crawl (`rust/src/scanner/engine.rs`) ignores `D:\Flicks\.backups`.
6. Full test regression suite (`cargo test`, `probe_android_api.py`) passes.

---

## 4. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Secondary disk `D:` is unmounted, full, or asleep. | Secondary copy is wrapped in try/catch with structured warning. Failure to write to `D:` logs a warning in `backup_postgres.log` but does not fail or discard the primary backup on `E:`. |
| Partial copy on `D:` during abrupt power interruption. | Copy dump to a temporary `.tmp` file on `D:` first, verify size against source, then atomically rename to `.dump`. Incomplete files are never left in the rotation. |
| Media scanner descends into `D:\Flicks\.backups`. | Added `file_name != ".backups"` to `filter_entry` in `discover_video_files`. |

---

## 5. Open Decisions for User Approval

- **Decision 1: Secondary Mirror Location on Drive `D:`**
  - **Option A (Recommended):** `D:\Flicks\.backups\postgres` — keeps media server data consolidated under `D:\Flicks` with dot-prefixed convention matching `.archive`, `.uploads`, and `.deleted`.
  - **Option B:** `D:\MediaServerBackups\postgres` — dedicated separate folder on the root of `D:`.
- **Decision 2: Secondary Retention Window**
  - **Option A (Recommended):** 14 days — provides 2 weeks of cold recovery history on the high-capacity secondary HDD while `E:` keeps 7 days.
  - **Option B:** 7 days — identical retention on both drives.
- **Decision 3: Off-Host Sync Hook**
  - **Option A (Recommended):** Include extensible command hook (`-PostBackupCommand` / `MEDIA_SERVER_POST_BACKUP_CMD`) for optional cloud/rclone/off-site automation.
  - **Option B:** Local dual-drive replication only without hook.
