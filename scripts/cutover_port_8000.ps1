# Cutover Port 8000: Transfer production port :8000 from Waitress (Flask) to MediaServerRust
# Requires Administrator privileges.

$ErrorActionPreference = "Continue"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "   Media Server - Production Port 8000 Cutover      " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# Check for Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevated Administrator privileges required. Requesting UAC elevation..." -ForegroundColor Yellow
    powershell.exe -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File `\"$PSCommandPath`\"' -WorkingDirectory 'E:\MediaServer' -Verb RunAs"
    exit 0
}

$BaseDir = "E:\MediaServer"
$RustDir = "$BaseDir\rust"
$LogFile = "$BaseDir\logs\cutover.log"
Start-Transcript -Path $LogFile -Force -ErrorAction SilentlyContinue

# 1. Stop legacy MediaServer (Waitress WSGI)
Write-Host "`n[1/6] Stopping legacy 'MediaServer' (Waitress WSGI) Windows Service..." -ForegroundColor Yellow
$legacySvc = Get-Service -Name "MediaServer" -ErrorAction SilentlyContinue
if ($legacySvc) {
    Stop-Service -Name "MediaServer" -Force -ErrorAction SilentlyContinue
    Set-Service -Name "MediaServer" -StartupType Manual -ErrorAction SilentlyContinue
    Write-Host "  Legacy 'MediaServer' service stopped and set to Manual startup." -ForegroundColor Green
} else {
    Write-Host "  'MediaServer' service not found." -ForegroundColor DarkGray
}

# 2. Stop MediaServerRust to unlock binary and port 8001
Write-Host "`n[2/6] Stopping 'MediaServerRust' service..." -ForegroundColor Yellow
$rustSvc = Get-Service -Name "MediaServerRust" -ErrorAction SilentlyContinue
if ($rustSvc) {
    Stop-Service -Name "MediaServerRust" -Force -ErrorAction SilentlyContinue
}

# 3. Wait for binary and port 8000 release
Write-Host "`n[3/6] Waiting for port 8000 and binary release..." -ForegroundColor Yellow
for ($i = 0; $i -lt 30; $i++) {
    $proc = Get-Process -Name "media-server-api" -ErrorAction SilentlyContinue
    $p8000 = Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue
    if (-not $proc -and -not $p8000) {
        Write-Host "  Port 8000 is free and binary is released." -ForegroundColor Green
        break
    }
    Start-Sleep -Seconds 1
}

# Force terminate any remaining process on port 8000
$rem8000 = Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue
if ($rem8000) {
    $pids = $rem8000 | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($p in $pids) {
        if ($p -gt 4) {
            Write-Host "  Terminating lingering process on port 8000 (PID: $p)..." -ForegroundColor Yellow
            Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        }
    }
}
Get-Process -Name "media-server-api" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# 4. Compile latest release binary
Write-Host "`n[4/6] Compiling latest Rust release binary with MSVC..." -ForegroundColor Yellow
& "$BaseDir\scripts\cargo.bat" build --release --manifest-path "$RustDir\Cargo.toml"
if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: Release compilation failed. Aborting cutover." -ForegroundColor Red
    exit 1
}
Write-Host "  Compilation succeeded." -ForegroundColor Green

# 5. Reconfigure MediaServerRust NSSM Registry to Port 8000
Write-Host "`n[5/6] Updating 'MediaServerRust' NSSM environment to RUST_PORT=8000..." -ForegroundColor Yellow
$regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\MediaServerRust\Parameters"
if (Test-Path $regKey) {
    $envLines = (Get-ItemProperty -Path $regKey -Name "AppEnvironmentExtra").AppEnvironmentExtra
    $updatedLines = @()
    $hasPort = $false
    foreach ($line in $envLines) {
        if ($line -like "RUST_PORT=*") {
            $updatedLines += "RUST_PORT=8000"
            $hasPort = $true
        } else {
            $updatedLines += $line
        }
    }
    if (-not $hasPort) {
        $updatedLines += "RUST_PORT=8000"
    }
    Set-ItemProperty -Path $regKey -Name "AppEnvironmentExtra" -Value $updatedLines
    Write-Host "  Registry updated: RUST_PORT=8000" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Registry key $regKey not found. Service might be running standalone." -ForegroundColor Yellow
}

# 6. Start MediaServerRust
Write-Host "`n[6/6] Starting 'MediaServerRust' on Port 8000..." -ForegroundColor Cyan
if ($rustSvc) {
    Start-Service -Name "MediaServerRust"
    Start-Sleep -Seconds 3
    $startedSvc = Get-Service -Name "MediaServerRust"
    Write-Host "  Service Status: $($startedSvc.Status)" -ForegroundColor Green
} else {
    Write-Host "  Running standalone..." -ForegroundColor Yellow
    $env:RUST_PORT = "8000"
    $env:RUST_HOST = "0.0.0.0"
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"`"$RustDir\target\release\media-server-api.exe`" >> `"$BaseDir\logs\rust_api.log`" 2>> `"$BaseDir\logs\rust_api_error.log`"`"" -WorkingDirectory $BaseDir -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

# 7. Verification Probe
Write-Host "`n--- Verification Probes on Port 8000 ---" -ForegroundColor Cyan
$conn = Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn) {
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "Listening Process on :8000: $($proc.ProcessName) (PID: $($proc.Id), Memory: $([math]::Round($proc.WorkingSet64/1MB, 1)) MB)" -ForegroundColor Green
} else {
    Write-Host "ERROR: Port 8000 is NOT listening!" -ForegroundColor Red
}

try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:8000/health" -TimeoutSec 5
    Write-Host "Local Health Probe (http://127.0.0.1:8000/health): $($health | ConvertTo-Json -Compress)" -ForegroundColor Green
} catch {
    Write-Host "Health Probe Failed: $_" -ForegroundColor Red
}

try {
    $spa = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -UseBasicParsing -TimeoutSec 5
    Write-Host "Local SPA Probe (http://127.0.0.1:8000/): HTTP $($spa.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "SPA Probe Failed: $_" -ForegroundColor Red
}

Write-Host "`n====================================================" -ForegroundColor Green
Write-Host "   Port 8000 Cutover Completed Successfully!        " -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green
