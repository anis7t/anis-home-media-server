# Restore the PostgreSQL 'media_server' database from a pg_dump custom-format archive.
#
# The counterpart to backup_postgres.ps1. Two safety properties matter here:
#
#  1. It takes a rollback point of the CURRENT database before it touches
#     anything. If the restore turns out to be the wrong dump, the previous
#     state is still on disk.
#  2. It refuses to restore over the live database without an explicit
#     -Confirm, and it says plainly that MediaServerRust must be stopped
#     first. Restoring under a running server means the app holds pooled
#     connections against objects that are being dropped and recreated.
#
# Use -TargetDatabase to restore into a scratch database instead - that is the
# safe way to verify a dump before trusting it with the real one.

param(
    # Path to the .dump archive. Defaults to the newest one in the backup store.
    [string]$DumpFile,

    [string]$Database = "media_server",
    [string]$TargetDatabase,
    [string]$User = "postgres",
    [string]$DbHost = "127.0.0.1",
    [int]$Port = 5432,
    [string]$DestDir = "E:\MediaServer\backups\postgres",

    # Skip the pre-restore rollback point (only sensible for a scratch target).
    [switch]$NoRollbackPoint,

    # Actually perform the restore. Without this, the script only inspects.
    [switch]$Confirm
)

$ErrorActionPreference = "Stop"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         PostgreSQL Database Restore Tool           " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# --- Locate the PostgreSQL binaries -----------------------------------------
$binRoot = $null
foreach ($c in @("C:\postgres\pgsql\bin", "E:\postgres\pgsql\bin")) {
    if (Test-Path (Join-Path $c "pg_restore.exe")) { $binRoot = $c; break }
}
if (-not $binRoot) {
    $cmd = Get-Command "pg_restore.exe" -ErrorAction SilentlyContinue
    if ($cmd) { $binRoot = Split-Path $cmd.Source }
}
if (-not $binRoot) {
    Write-Host "ERROR: pg_restore.exe was not found in the standard paths." -ForegroundColor Red
    exit 1
}
$pgRestore = Join-Path $binRoot "pg_restore.exe"
$pgDump    = Join-Path $binRoot "pg_dump.exe"
$psql      = Join-Path $binRoot "psql.exe"
$env:PGPASSWORD = if ($env:PGPASSWORD) { $env:PGPASSWORD } else { "postgres" }

# --- Resolve the dump -------------------------------------------------------
if (-not $DumpFile) {
    $newest = Get-ChildItem -Path $DestDir -Filter "${Database}_*.dump" -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending | Select-Object -First 1
    if (-not $newest) { $newest = Get-ChildItem -Path $DestDir -Filter "*.dump" -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending | Select-Object -First 1 }
    if (-not $newest) {
        Write-Host "ERROR: no .dump archive found in $DestDir. Pass -DumpFile explicitly." -ForegroundColor Red
        exit 1
    }
    $DumpFile = $newest.FullName
}
if (-not (Test-Path $DumpFile)) {
    Write-Host "ERROR: dump file not found: $DumpFile" -ForegroundColor Red
    exit 1
}
$DumpFile = (Resolve-Path $DumpFile).Path

Write-Host "Archive : $DumpFile" -ForegroundColor DarkGray
Write-Host "Size    : $([math]::Round((Get-Item $DumpFile).Length / 1KB, 1)) KB" -ForegroundColor DarkGray
Write-Host "Taken   : $((Get-Item $DumpFile).CreationTime)" -ForegroundColor DarkGray

# --- Verify the archive is a readable custom-format dump --------------------
Write-Host "`n[1/4] Verifying the archive is a valid custom-format dump..." -ForegroundColor Cyan
$listing = & $pgRestore --list $DumpFile 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: the archive could not be read by pg_restore:" -ForegroundColor Red
    Write-Host $listing -ForegroundColor Red
    exit 1
}
# The header carries the authoritative count; the body lines are "<oid>; <type> <schema> <name>".
$tocHeader = $listing | Where-Object { $_ -match "TOC Entries:\s*(\d+)" } | Select-Object -First 1
$tocCount = if ($tocHeader -and $tocHeader -match "TOC Entries:\s*(\d+)") { $Matches[1] } else { "?" }
$entryCount = ($listing | Where-Object { $_ -match "^\s*\d+;\s" }).Count
Write-Host "  OK - archive is readable. TOC entries: $tocCount (listed: $entryCount)." -ForegroundColor Green

$isTargetLive = (-not $TargetDatabase) -or ($TargetDatabase -eq $Database)
if (-not $Confirm) {
    Write-Host "`nDRY RUN - nothing was changed." -ForegroundColor Yellow
    if ($isTargetLive) {
        Write-Host "`nTo actually restore over '$Database', re-run with -Confirm." -ForegroundColor Yellow
        Write-Host "  STOP MediaServerRust FIRST:  Stop-Service MediaServerRust" -ForegroundColor Yellow
    } else {
        Write-Host "`nTo restore into '$TargetDatabase', re-run with -Confirm." -ForegroundColor Yellow
    }
    exit 0
}

# --- Pre-restore rollback point ---------------------------------------------
if ($isTargetLive -and -not $NoRollbackPoint) {
    Write-Host "`n[2/4] Taking a rollback point of the current '$Database'..." -ForegroundColor Cyan
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $rb = Join-Path $DestDir "${Database}_prerestore_${stamp}.dump"
    & $pgDump -h $DbHost -p $Port -U $User -d $Database -F c -b -f "`"$rb`"" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $rb)) {
        Write-Host "  Rollback point saved: $rb" -ForegroundColor Green
    } else {
        Write-Host "  ERROR: could not create a rollback point. Aborting - refusing to restore without one." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "`n[2/4] Rollback point skipped." -ForegroundColor DarkGray
}

# --- Restore ----------------------------------------------------------------
$target = if ($TargetDatabase) { $TargetDatabase } else { $Database }
Write-Host "`n[3/4] Restoring into '$target'..." -ForegroundColor Cyan
if ($isTargetLive) {
    Write-Host "  NOTE: --clean drops existing objects before recreating them." -ForegroundColor DarkGray
}
& $pgRestore -h $DbHost -p $Port -U $User -d $target --clean --if-exists --no-owner --no-privileges $DumpFile
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    Write-Host "`nERROR: pg_restore exited with code $rc." -ForegroundColor Red
    Write-Host "The target database may be partially restored." -ForegroundColor Red
    if ($isTargetLive -and -not $NoRollbackPoint) {
        Write-Host "A rollback point was taken before this attempt - see $DestDir." -ForegroundColor Yellow
    }
    exit $rc
}

# --- Verify -----------------------------------------------------------------
Write-Host "`n[4/4] Verifying the restored database..." -ForegroundColor Cyan
$checks = @("movies", "users", "sessions", "progress", "devices", "settings", "auth_tokens")
$ok = $true
foreach ($t in $checks) {
    $count = (& $psql -h $DbHost -p $Port -U $User -d $target -A -t -c "SELECT count(*) FROM $t;" 2>$null)
    if ($null -eq $count -or $count -eq "") {
        Write-Host ("  {0,-16} MISSING" -f $t) -ForegroundColor Red
        $ok = $false
    } else {
        Write-Host ("  {0,-16} {1} rows" -f $t, $count.Trim()) -ForegroundColor DarkGray
    }
}

if ($ok) {
    Write-Host "`nRESTORE COMPLETE." -ForegroundColor Green
    if ($isTargetLive) {
        Write-Host "Now start the server:  Start-Service MediaServerRust" -ForegroundColor Green
        Write-Host "The Rust server creates any missing tables at pool creation, so a dump" -ForegroundColor DarkGray
        Write-Host "taken before a schema change is still safe to restore." -ForegroundColor DarkGray
    }
} else {
    Write-Host "`nRESTORE COMPLETED BUT VERIFICATION FOUND MISSING TABLES." -ForegroundColor Yellow
    exit 1
}
