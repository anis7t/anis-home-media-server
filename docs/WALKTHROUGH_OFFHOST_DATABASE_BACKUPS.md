# Walkthrough — Off-Host Database Backups (Category 5.5)

## 1. Executive Summary

We have fully implemented, tested, and verified **Category 5.5: Off-Host Database Backups**.

- **Eliminated Single-Drive Point of Failure:** Previously, both the active PostgreSQL database (`E:\pgdata`) and the daily backups (`E:\MediaServer\backups\postgres`) resided on the same physical SSD drive (`E:`). A drive crash or filesystem corruption on `E:` would result in total, unrecoverable data loss.
- **Cross-Volume Secondary Mirroring (Option A):** In [`scripts/backup_postgres.ps1`](../scripts/backup_postgres.ps1), backups are now automatically mirrored to the secondary disk `D:` at `D:\Flicks\.backups\postgres`. Replication uses an atomic temporary file (`.tmp`) with source byte-size verification before promotion, guaranteeing no partial or corrupt dumps enter the secondary archive.
- **Pre-Replication Archive Integrity Verification:** Prior to rotation pruning or replication, the script runs `pg_restore --list` directly against the new `.dump` file to verify that the gzip custom format header and table of contents are valid and uncorrupted.
- **Independent 14-Day Cold Recovery Retention (Option A):** Primary SSD backups retain the newest 7 days of scheduled backups, while secondary HDD backups on `D:` retain **14 days**, providing two full weeks of cold disaster recovery history.
- **Automated Disaster Recovery Fallback in Restore Tool:** In [`scripts/restore_postgres.ps1`](../scripts/restore_postgres.ps1), if the primary backup store on `E:` is empty or missing due to drive loss, the tool automatically detects and resolves the latest valid dump from secondary storage `D:\Flicks\.backups\postgres`.
- **Media Scanner Ignore Rule:** Added `.backups` to `ScannerEngine::discover_video_files` in [`rust/src/scanner/engine.rs`](../rust/src/scanner/engine.rs) to ensure scanner crawls under `D:\Flicks` ignore backup archives.
- **Extensible Sync Hook:** Added `-PostBackupCommand` and `MEDIA_SERVER_POST_BACKUP_CMD` support to chain external cloud or off-site storage tools (e.g. `rclone`, `aws s3`).
- **Comprehensive Verification:** Verified backup generation, integrity verification (TOC entries: 84), secondary replication, rotation pruning, restore dry-run on primary and secondary fallback, Rust suite (125 tests), and Android API contract suite (22/22 endpoints).

---

## 2. Changes Implemented

### A. Enhanced Backup Script (`scripts/backup_postgres.ps1`)
1. **Added Secondary Destination & Hook Parameters:**
   ```powershell
   param(
       [string]$Database = "media_server",
       [string]$User = "postgres",
       [string]$DbHost = "127.0.0.1",
       [int]$Port = 5432,
       [string]$DestDir = "E:\MediaServer\backups\postgres",
       [int]$Keep = 7,
       [int]$KeepRollbacks = 3,
       [string]$SecondaryDestDir = "D:\Flicks\.backups\postgres",
       [int]$KeepSecondary = 14,
       [string]$PostBackupCommand = ""
   )
   ```
2. **Pre-Replication Integrity Verification:**
   ```powershell
   Write-Host "`n[2/4] Verifying archive integrity..." -ForegroundColor Yellow
   if ($pgRestore -and (Test-Path $pgRestore)) {
       $tocOutput = & $pgRestore --list "$dumpFile" 2>&1
       if ($LASTEXITCODE -ne 0) {
           Write-Host "ERROR: pg_restore verification failed. Dump may be corrupted." -ForegroundColor Red
           exit 1
       }
       $tocMatch = $tocOutput | Where-Object { $_ -match "TOC Entries:\s*(\d+)" } | Select-Object -First 1
       $entriesCount = if ($tocMatch -and $tocMatch -match "TOC Entries:\s*(\d+)") { $Matches[1] } else { "?" }
       Write-Host "SUCCESS: Archive verified healthy (TOC Entries: $entriesCount)" -ForegroundColor Green
   }
   ```
3. **Atomic Cross-Volume Secondary Mirroring & Retention:**
   ```powershell
   # Copy to temporary file first to guarantee atomic write
   Copy-Item -Path $dumpFile -Destination $secondaryTmp -Force

   # Verify byte size matches source
   $srcSize = (Get-Item $dumpFile).Length
   $dstSize = (Get-Item $secondaryTmp).Length
   if ($srcSize -ne $dstSize) {
       Remove-Item -Path $secondaryTmp -Force -ErrorAction SilentlyContinue
       throw "Size mismatch on secondary copy ($srcSize vs $dstSize bytes)"
   }

   # Atomically rename into place
   Move-Item -Path $secondaryTmp -Destination $secondaryFinal -Force

   # Prune secondary destination backups (Keep: 14)
   if ($KeepSecondary -gt 0) { ... }
   ```

### B. Disaster Recovery Fallback in Restore Tool (`scripts/restore_postgres.ps1`)
```powershell
if (-not $newest -and $SecondaryDestDir -and (Test-Path $SecondaryDestDir)) {
    Write-Host "NOTE: No dumps found in primary $DestDir. Checking secondary storage: $SecondaryDestDir ..." -ForegroundColor Yellow
    $newest = Get-ChildItem -Path $SecondaryDestDir -Filter "${Database}_*.dump" -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending | Select-Object -First 1
    if ($newest) {
        Write-Host "DISASTER RECOVERY FALLBACK: Selected backup from secondary storage ($($newest.FullName))" -ForegroundColor Cyan
    }
}
```

### C. Media Scanner Ignore Rule (`rust/src/scanner/engine.rs`)
```rust
// Skip temporary uploads, deleted bins, caches, backups, node modules, build targets, and git
file_name != ".uploads"
    && file_name != ".deleted"
    && file_name != ".backups"
    && file_name != "cache"
    && file_name != ".git"
    && file_name != "target"
    && file_name != "node_modules"
    && file_name != ".venv"
```

---

## 3. Verification & Live Drill Outcomes

### 1. Live Backup & Replication Drill
Executing `powershell -ExecutionPolicy Bypass -File E:\MediaServer\scripts\backup_postgres.ps1`:
```text
====================================================
         PostgreSQL Database Backup Tool            
====================================================
Using pg_dump   : C:\postgres\pgsql\bin\pg_dump.exe
Using pg_restore: C:\postgres\pgsql\bin\pg_restore.exe

[1/4] Creating primary backup: E:\MediaServer\backups\postgres\media_server_20261024_143035.dump ...
SUCCESS: Primary backup created (0.08 MB)

[2/4] Verifying archive integrity...
SUCCESS: Archive verified healthy (TOC Entries: 84)

[3/4] Enforcing primary backup retention (Keep: 7)...
Pruning old primary backup: media_server_20261017_235548.dump
Primary retention enforced. Retained newest 7 scheduled backups.

[4/4] Cross-volume secondary replication (Secondary: D:\Flicks\.backups\postgres)...
SUCCESS: Replicated to secondary storage: D:\Flicks\.backups\postgres\media_server_20261024_143035.dump (0.08 MB)
Secondary retention enforced. Retained newest 14 backups on secondary volume.

====================================================
SUCCESS: Backup operation fully completed.
====================================================
```

### 2. Secondary Archive TOC Verification
Running `pg_restore.exe --list D:\Flicks\.backups\postgres\media_server_20261024_143035.dump`:
```text
; Archive created at 2026-10-24 14:30:35
;     dbname: media_server
;     TOC Entries: 84
;     Compression: gzip
;     Dump Version: 1.16-0
;     Format: CUSTOM
;     Dumped from database version: 18.4
```

### 3. Restore Tool Primary & Disaster Recovery Fallback
- **Primary Resolution:** `restore_postgres.ps1` resolves `E:\MediaServer\backups\postgres\media_server_20261024_143035.dump` (84 TOC entries).
- **Secondary Fallback Resolution:** When `-DestDir` points to an empty directory, `restore_postgres.ps1` outputs:
  ```text
  NOTE: No dumps found in primary <dir>. Checking secondary storage: D:\Flicks\.backups\postgres ...
  DISASTER RECOVERY FALLBACK: Selected backup from secondary storage (D:\Flicks\.backups\postgres\media_server_20261024_143035.dump)
  Archive : D:\Flicks\.backups\postgres\media_server_20261024_143035.dump
  Size    : 86.5 KB
  [1/4] Verifying the archive is a valid custom-format dump...
    OK - archive is readable. TOC entries: 84 (listed: 80).
  ```

### 4. Automated Regression Suite
- `cargo test --lib`: 125/125 tests passed.
- `cargo test --test subtitle_test`: 5/5 tests passed.
- `cargo test --test qr_auth_test`: 5/5 tests passed.
- `cargo test --test audit_log_test`: 7/7 tests passed.
- `cargo test --test user_progress_test`: 4/4 tests passed.
- `cargo test --test admin_auth_test -- --test-threads=1`: 6/6 tests passed.
- `cargo test --test api_contracts_test`: 4/4 tests passed.
- `python scripts/probe_android_api.py`: 22/22 endpoints passed.
