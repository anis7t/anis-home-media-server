# Install and register MediaServerRust as a persistent Windows Service using NSSM
# Run this script with Administrator privileges (will auto-prompt if not elevated).

$ErrorActionPreference = "Stop"

# 1. Ensure Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevated Administrator privileges are required to register Windows Services." -ForegroundColor Yellow
    if (Get-Command sudo.exe -ErrorAction SilentlyContinue) {
        Write-Host "Launching elevated session via Windows sudo..." -ForegroundColor Cyan
        sudo.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath"
        exit $LASTEXITCODE
    } else {
        Write-Host "Please run this script from an elevated PowerShell window (Run as Administrator)." -ForegroundColor Red
        exit 1
    }
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "   Installing MediaServerRust as a Windows Service  " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$BaseDir = "E:\MediaServer"
$RustDir = "$BaseDir\rust"
$BinDir = "$BaseDir\bin"
$LogsDir = "$BaseDir\logs"
$NssmExe = "$BinDir\nssm.exe"

# 2. Ensure directories exist
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }
if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }

# 3. Ensure NSSM binary exists
if (-not (Test-Path $NssmExe)) {
    Write-Host "Downloading NSSM (Non-Sucking Service Manager)..." -ForegroundColor Yellow
    $zipPath = "$BinDir\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath "$BinDir\temp_nssm" -Force
    Copy-Item "$BinDir\temp_nssm\nssm-2.24\win64\nssm.exe" -Destination $NssmExe -Force
    Remove-Item -Recurse -Force "$BinDir\temp_nssm", $zipPath
    Write-Host "NSSM installed to $NssmExe" -ForegroundColor Green
}

# 4. Check / Start PostgreSQL
$pgConn = Get-NetTCPConnection -LocalPort 5432 -ErrorAction SilentlyContinue
if (-not $pgConn) {
    Write-Host "PostgreSQL is not running on port 5432. Starting PostgreSQL..." -ForegroundColor Yellow
    & "$BaseDir\scripts\start_postgres.bat"
    Start-Sleep -Seconds 2
}

# 5. Resolve or build Rust Binary
$releaseExe = "$RustDir\target\release\media-server-api.exe"
$debugExe = "$RustDir\target\debug\media-server-api.exe"

if (Test-Path $releaseExe) {
    $exePath = $releaseExe
    Write-Host "Using release binary: $exePath" -ForegroundColor Green
} elseif (Test-Path $debugExe) {
    $exePath = $debugExe
    Write-Host "Using debug binary: $exePath" -ForegroundColor Yellow
} else {
    Write-Host "Building Rust binary via cargo.bat..." -ForegroundColor Yellow
    & "$BaseDir\scripts\cargo.bat" build --release --manifest-path "$RustDir\Cargo.toml"
    if (Test-Path $releaseExe) {
        $exePath = $releaseExe
    } else {
        throw "Failed to locate compiled Rust binary at $releaseExe"
    }
}

# 6. Stop any existing processes on port 8000
Write-Host "Checking for existing processes on port 8000..." -ForegroundColor Yellow
$connections = Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue
if ($connections) {
    $pids = $connections | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($p in $pids) {
        if ($p -gt 4) {
            Write-Host "Terminating existing process on port 8000 (PID: $p)..." -ForegroundColor Yellow
            Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        }
    }
}

# 7. Check if service already exists
$serviceName = "MediaServerRust"
$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Stopping existing $serviceName service..." -ForegroundColor Yellow
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    # NSSM holds media-server-api.exe past the return of Stop-Service; a fixed
    # 2s sleep is not reliably enough and a build attempted while it is still
    # open fails with "Access is denied", silently keeping the old binary.
    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Get-Process -Name "media-server-api" -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Seconds 2
    }
    Get-Process -Name "media-server-api" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Creating new $serviceName service..." -ForegroundColor Yellow
    & $NssmExe install $serviceName $exePath
}

# 8. Configure Service Parameters via NSSM
Write-Host "Configuring service parameters..." -ForegroundColor Yellow
& $NssmExe set $serviceName Application $exePath
& $NssmExe set $serviceName AppDirectory $BaseDir
& $NssmExe set $serviceName DisplayName "Media Server API (Rust/Axum)"
& $NssmExe set $serviceName Description "Self-hosted personal media streaming server backend running Rust Axum on port 8000"
& $NssmExe set $serviceName Start SERVICE_AUTO_START

# Logging configuration
& $NssmExe set $serviceName AppStdout "$LogsDir\rust_api.log"
& $NssmExe set $serviceName AppStderr "$LogsDir\rust_api_error.log"
& $NssmExe set $serviceName AppRotateFiles 1
& $NssmExe set $serviceName AppRotateOnline 1
& $NssmExe set $serviceName AppRotateSeconds 86400
& $NssmExe set $serviceName AppRotateBytes 10485760

# Restart policy on crash / unexpected exit
& $NssmExe set $serviceName AppRestartDelay 5000
sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/5000/restart/10000 | Out-Null

# Environment variables injection
$ExtraPath = "C:\Users\anis7\AppData\Local\Microsoft\WinGet\Links;C:\Python314\Scripts;C:\Python314;E:\postgres\pgsql\bin;$env:PATH"
$envExtra = "PATH=$ExtraPath`nMEDIA_SERVER_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/media_server`nRUST_HOST=0.0.0.0`nRUST_PORT=8000`nMEDIA_SERVER_MEDIA_ROOT=D:\Flicks`nMEDIA_SERVER_MEDIA_ROOTS=D:\Flicks,D:\Flicks\.archive`nMEDIA_SERVER_CACHE_DIR=E:\MediaServer\cache`nMEDIA_SERVER_STATIC_DIR=E:\MediaServer\web\dist`nMEDIA_SERVER_BASE_DIR=E:\MediaServer`nRUST_LOG=info"
& $NssmExe set $serviceName AppEnvironmentExtra $envExtra

# 8b. Firewall: allow inbound on this executable.
$RuleName = "MediaServerRust (media-server-api.exe)"
$ExePath = "$RustDir\target\release\media-server-api.exe"
if (Test-Path $ExePath) {
    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Firewall rule '$RuleName' already present." -ForegroundColor DarkGray
    } else {
        New-NetFirewallRule -DisplayName $RuleName `
            -Direction Inbound -Action Allow -Program $ExePath `
            -Profile Private,Domain `
            -Enabled True | Out-Null
        Write-Host "Created firewall rule: $RuleName" -ForegroundColor Green
    }
} else {
    Write-Host "WARNING: $ExePath not found; no firewall rule created." -ForegroundColor Yellow
}

# 9. Start the Service
Write-Host "Starting $serviceName service..." -ForegroundColor Cyan
Start-Service -Name $serviceName
Start-Sleep -Seconds 3

# 10. Verify Status
$svc = Get-Service -Name $serviceName
Write-Host "Service '$serviceName' status: $($svc.Status) (Startup: $($svc.StartType))" -ForegroundColor Green

# 11. Verify Local HTTP Response
Write-Host "Testing local HTTP endpoint (http://127.0.0.1:8000)..." -ForegroundColor Yellow
try {
    $res = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -UseBasicParsing -TimeoutSec 5
    Write-Host "Local HTTP SPA probe SUCCESS! Status: $($res.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "Local SPA probe warning: $_" -ForegroundColor Yellow
}

try {
    $apiRes = Invoke-WebRequest -Uri "http://127.0.0.1:8000/api/movies" -UseBasicParsing -TimeoutSec 5
    Write-Host "Local API probe SUCCESS! Status: $($apiRes.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "Local API probe warning: $_" -ForegroundColor Yellow
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Deployment Complete! Media Server Rust runs         " -ForegroundColor Green
Write-Host " automatically at boot on port 8000.                " -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
