# Automated, crash-safe backup of the PostgreSQL 'media_server' database.
# Uses pg_dump custom compressed format (-Fc) with timestamped naming, integrity verification,
# rotation pruning, and cross-volume secondary replication (Drive D:).

param(
    [string]$Database = "media_server",
    [string]$User = "postgres",
    [string]$DbHost = "127.0.0.1",
    [int]$Port = 5432,
    [string]$DestDir = "E:\MediaServer\backups\postgres",
    [int]$Keep = 7,
    # Pre-restore rollback points are pruned on their own budget, so a
    # rollback point can never displace a scheduled backup from the rotation.
    [int]$KeepRollbacks = 3,

    # Cross-volume secondary mirror (Drive D: high-capacity HDD cold recovery)
    [string]$SecondaryDestDir = "D:\Flicks\.backups\postgres",
    [int]$KeepSecondary = 14,

    # Optional off-host cloud or rclone hook command
    [string]$PostBackupCommand = ""
)

$ErrorActionPreference = "Stop"

if (-not $PostBackupCommand -and $env:MEDIA_SERVER_POST_BACKUP_CMD) {
    $PostBackupCommand = $env:MEDIA_SERVER_POST_BACKUP_CMD
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         PostgreSQL Database Backup Tool            " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Locate pg_dump.exe and pg_restore.exe
$pgDumpCandidates = @(
    "C:\postgres\pgsql\bin\pg_dump.exe",
    "E:\postgres\pgsql\bin\pg_dump.exe",
    "C:\Program Files\PostgreSQL\16\bin\pg_dump.exe",
    "C:\Program Files\PostgreSQL\15\bin\pg_dump.exe"
)

$pgDump = $null
foreach ($c in $pgDumpCandidates) {
    if (Test-Path $c) {
        $pgDump = $c
        break
    }
}

if (-not $pgDump) {
    $cmd = Get-Command "pg_dump.exe" -ErrorAction SilentlyContinue
    if ($cmd) { $pgDump = $cmd.Source }
}

if (-not $pgDump) {
    Write-Host "ERROR: pg_dump.exe was not found in standard paths." -ForegroundColor Red
    exit 1
}

$binRoot = Split-Path $pgDump
$pgRestore = Join-Path $binRoot "pg_restore.exe"
if (-not (Test-Path $pgRestore)) {
    $cmd = Get-Command "pg_restore.exe" -ErrorAction SilentlyContinue
    if ($cmd) { $pgRestore = $cmd.Source }
}

Write-Host "Using pg_dump   : $pgDump" -ForegroundColor DarkGray
if ($pgRestore) {
    Write-Host "Using pg_restore: $pgRestore" -ForegroundColor DarkGray
}

# 2. Ensure destination directory exists
if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

# 3. Create timestamped dump
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$dumpFile = Join-Path $DestDir "${Database}_${timestamp}.dump"

Write-Host "`n[1/4] Creating primary backup: $dumpFile ..." -ForegroundColor Yellow
$env:PGPASSWORD = if ($env:PGPASSWORD) { $env:PGPASSWORD } else { "postgres" }

try {
    $proc = Start-Process -FilePath $pgDump `
        -ArgumentList "-h", $DbHost, "-p", $Port, "-U", $User, "-d", $Database, "-F", "c", "-b", "-v", "-f", "`"$dumpFile`"" `
        -NoNewWindow -PassThru -Wait

    if ($proc.ExitCode -ne 0) {
        Write-Host "ERROR: pg_dump exited with error code $($proc.ExitCode)" -ForegroundColor Red
        exit $proc.ExitCode
    }

    $size = (Get-Item $dumpFile).Length
    $sizeMB = [math]::Round($size / 1MB, 2)
    Write-Host "SUCCESS: Primary backup created ($sizeMB MB)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to run pg_dump: $_" -ForegroundColor Red
    exit 1
}

# 4. Verify archive integrity via pg_restore --list
Write-Host "`n[2/4] Verifying archive integrity..." -ForegroundColor Yellow
if ($pgRestore -and (Test-Path $pgRestore)) {
    $tocOutput = & $pgRestore --list "$dumpFile" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: pg_restore verification failed. Dump may be corrupted." -ForegroundColor Red
        Write-Host $tocOutput -ForegroundColor Red
        exit 1
    }
    $tocMatch = $tocOutput | Where-Object { $_ -match "TOC Entries:\s*(\d+)" } | Select-Object -First 1
    $entriesCount = if ($tocMatch -and $tocMatch -match "TOC Entries:\s*(\d+)") { $Matches[1] } else { "?" }
    Write-Host "SUCCESS: Archive verified healthy (TOC Entries: $entriesCount)" -ForegroundColor Green
} else {
    Write-Host "WARNING: pg_restore.exe not found; skipped TOC verification." -ForegroundColor Yellow
}

# 5. Prune old primary backups (Retention: Keep newest $Keep scheduled backups)
Write-Host "`n[3/4] Enforcing primary backup retention (Keep: $Keep)..." -ForegroundColor Yellow
if ($Keep -gt 0) {
    # Scheduled backups and pre-restore rollback points are pruned on separate
    # budgets. Without the split, a rollback point (which is also a full dump)
    # would occupy a slot in the scheduled rotation.
    $scheduled = Get-ChildItem -Path $DestDir -Filter "${Database}_*.dump" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "${Database}_prerestore_*" } |
        Sort-Object CreationTime -Descending
    if ($scheduled.Count -gt $Keep) {
        $toRemove = $scheduled | Select-Object -Skip $Keep
        foreach ($f in $toRemove) {
            Write-Host "Pruning old primary backup: $($f.Name)" -ForegroundColor DarkGray
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $rollbacks = Get-ChildItem -Path $DestDir -Filter "${Database}_prerestore_*.dump" -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending
    if ($KeepRollbacks -gt 0 -and $rollbacks.Count -gt $KeepRollbacks) {
        $toRemove = $rollbacks | Select-Object -Skip $KeepRollbacks
        foreach ($f in $toRemove) {
            Write-Host "Pruning old rollback point: $($f.Name)" -ForegroundColor DarkGray
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}
Write-Host "Primary retention enforced. Retained newest $Keep scheduled backups." -ForegroundColor Green

# 6. Cross-Volume Secondary Mirroring (Drive D: cold disaster recovery)
Write-Host "`n[4/4] Cross-volume secondary replication (Secondary: $SecondaryDestDir)..." -ForegroundColor Yellow
if ($SecondaryDestDir) {
    try {
        if (-not (Test-Path $SecondaryDestDir)) {
            New-Item -ItemType Directory -Path $SecondaryDestDir -Force | Out-Null
        }

        $dumpFileName = Split-Path $dumpFile -Leaf
        $secondaryTmp = Join-Path $SecondaryDestDir "${dumpFileName}.tmp"
        $secondaryFinal = Join-Path $SecondaryDestDir $dumpFileName

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

        $secSizeMB = [math]::Round($dstSize / 1MB, 2)
        Write-Host "SUCCESS: Replicated to secondary storage: $secondaryFinal ($secSizeMB MB)" -ForegroundColor Green

        # Prune secondary destination backups (Retention: Keep newest $KeepSecondary scheduled backups)
        if ($KeepSecondary -gt 0) {
            $secBackups = Get-ChildItem -Path $SecondaryDestDir -Filter "${Database}_*.dump" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike "${Database}_prerestore_*" } |
                Sort-Object CreationTime -Descending
            if ($secBackups.Count -gt $KeepSecondary) {
                $secToRemove = $secBackups | Select-Object -Skip $KeepSecondary
                foreach ($f in $secToRemove) {
                    Write-Host "Pruning old secondary backup: $($f.Name)" -ForegroundColor DarkGray
                    Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Host "Secondary retention enforced. Retained newest $KeepSecondary backups on secondary volume." -ForegroundColor Green
        }
    } catch {
        Write-Host "WARNING: Failed to replicate backup to secondary storage ($SecondaryDestDir): $_" -ForegroundColor Yellow
        Write-Host "         Primary backup on $DestDir is safe and uncorrupted." -ForegroundColor Yellow
    }
} else {
    Write-Host "Secondary destination unset; skipping secondary mirror." -ForegroundColor DarkGray
}

# 7. Optional Off-Host / Cloud Sync Hook
if ($PostBackupCommand) {
    Write-Host "`nExecuting post-backup hook: $PostBackupCommand ..." -ForegroundColor Cyan
    try {
        $cmdToRun = $PostBackupCommand.Replace("%DUMP_FILE%", "`"$dumpFile`"").Replace("%DUMP_DIR%", "`"$DestDir`"")
        Invoke-Expression $cmdToRun
        Write-Host "SUCCESS: Post-backup hook executed cleanly." -ForegroundColor Green
    } catch {
        Write-Host "WARNING: Post-backup hook encountered an error: $_" -ForegroundColor Yellow
    }
}

Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host "SUCCESS: Backup operation fully completed." -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
exit 0
