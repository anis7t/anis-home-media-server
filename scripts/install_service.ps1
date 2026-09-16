# Install and register MediaServer as a persistent Windows Service using NSSM
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
Write-Host "   Installing MediaServer as a Windows Service      " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$BaseDir = "C:\MediaServer"
$VenvPython = "$BaseDir\venv\Scripts\python.exe"
$RunScript = "$BaseDir\run_production.py"
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

# 4. Stop any existing processes on port 8000
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

# 5. Check if service already exists
$serviceName = "MediaServer"
$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Stopping existing $serviceName service..." -ForegroundColor Yellow
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
} else {
    Write-Host "Creating new $serviceName service..." -ForegroundColor Yellow
    & $NssmExe install $serviceName $VenvPython $RunScript
}

# 6. Configure Service Parameters via NSSM
Write-Host "Configuring service parameters..." -ForegroundColor Yellow
& $NssmExe set $serviceName AppDirectory $BaseDir
& $NssmExe set $serviceName DisplayName "Media Server WSGI (Waitress)"
& $NssmExe set $serviceName Description "Self-hosted personal media streaming server backend running Waitress on port 8000"
& $NssmExe set $serviceName Start SERVICE_AUTO_START

# Logging configuration
& $NssmExe set $serviceName AppStdout "$LogsDir\waitress.log"
& $NssmExe set $serviceName AppStderr "$LogsDir\waitress_error.log"
& $NssmExe set $serviceName AppRotateFiles 1
& $NssmExe set $serviceName AppRotateOnline 1
& $NssmExe set $serviceName AppRotateSeconds 86400
& $NssmExe set $serviceName AppRotateBytes 10485760

# Restart policy on crash / unexpected exit
& $NssmExe set $serviceName AppRestartDelay 5000

# Environment variables injection (ensure FFmpeg from winget links is always discoverable)
$ExtraPath = "C:\Users\anis7\AppData\Local\Microsoft\WinGet\Links;C:\Python314\Scripts;C:\Python314;$env:PATH"
& $NssmExe set $serviceName AppEnvironmentExtra "PATH=$ExtraPath`nMEDIA_SERVER_BASE_DIR=$BaseDir`nMEDIA_SERVER_MEDIA_ROOT=C:\Flicks`nMEDIA_SERVER_DATABASE=$BaseDir\media.db`nMEDIA_SERVER_ENABLE_AMF=1"

# 7. Start the Service
Write-Host "Starting $serviceName service..." -ForegroundColor Cyan
Start-Service -Name $serviceName
Start-Sleep -Seconds 3

# 8. Verify Status
$svc = Get-Service -Name $serviceName
Write-Host "Service '$serviceName' status: $($svc.Status) (Startup: $($svc.StartType))" -ForegroundColor Green

# 9. Verify Local HTTP Response
Write-Host "Testing local HTTP endpoint (http://127.0.0.1:8000)..." -ForegroundColor Yellow
try {
    $res = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -UseBasicParsing -TimeoutSec 5
    Write-Host "Local HTTP probe SUCCESS! Status: $($res.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "Local probe failed: $_" -ForegroundColor Red
}

# 10. Check Cloudflared Service Status
$cfSvc = Get-Service -Name "Cloudflared" -ErrorAction SilentlyContinue
if ($cfSvc) {
    Write-Host "Cloudflared service status: $($cfSvc.Status) (Startup: $($cfSvc.StartType))" -ForegroundColor Green
} else {
    Write-Host "Warning: Cloudflared service not found!" -ForegroundColor Yellow
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Deployment Complete! Media Server runs automatically" -ForegroundColor Green
Write-Host " at boot without requiring user logon.              " -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
