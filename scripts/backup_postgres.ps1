# Automated, crash-safe backup of the PostgreSQL 'media_server' database.
# Uses pg_dump custom compressed format (-Fc) with timestamped naming and rotation pruning.

param(
    [string]$Database = "media_server",
    [string]$User = "postgres",
    [string]$DbHost = "127.0.0.1",
    [int]$Port = 5432,
    [string]$DestDir = "E:\MediaServer\backups\postgres",
    [int]$Keep = 7
)

$ErrorActionPreference = "Stop"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         PostgreSQL Database Backup Tool            " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Locate pg_dump.exe
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

Write-Host "Using pg_dump: $pgDump" -ForegroundColor DarkGray

# 2. Ensure destination directory exists
if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

# 3. Create timestamped dump
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$dumpFile = Join-Path $DestDir "${Database}_${timestamp}.dump"

Write-Host "Creating backup: $dumpFile ..." -ForegroundColor Yellow
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
    Write-Host "SUCCESS: Backup created successfully ($sizeMB MB)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to run pg_dump: $_" -ForegroundColor Red
    exit 1
}

# 4. Prune old backups (Retention: Keep newest $Keep)
if ($Keep -gt 0) {
    $existing = Get-ChildItem -Path $DestDir -Filter "${Database}_*.dump" | Sort-Object CreationTime -Descending
    if ($existing.Count -gt $Keep) {
        $toRemove = $existing | Select-Object -Skip $Keep
        foreach ($f in $toRemove) {
            Write-Host "Pruning old backup: $($f.Name)" -ForegroundColor DarkGray
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "Backup operation complete. Retained newest $Keep backups." -ForegroundColor Green
exit 0
