# Restart MediaServerRust Service (or standalone dev instance)
# Run with Administrator privileges if managing Windows Service.

param(
    [switch]$NoRebuild
)

$ErrorActionPreference = "Continue"

# NSSM does not release media-server-api.exe the instant Stop-Service returns,
# and a 1-second sleep was not enough: cargo then failed with
# "Access is denied (os error 5)" and the script silently kept the PREVIOUS
# binary while still reporting success and probing a healthy service. That
# made a redeploy appear to work while the new code was never running - which
# is how a committed fix went unverified for several cycles.
# Poll until the process is actually gone before building.
function Wait-BinaryReleased([string]$ProcessName, [int]$TimeoutSec = 60) {
    for ($i = 0; $i -lt [int]($TimeoutSec / 2); $i++) {
        if (-not (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
            return $true
        }
    }
    return $false
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         Restarting Media Server Rust API           " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$BaseDir = "E:\MediaServer"
$RustDir = "$BaseDir\rust"
$BinDir = "$BaseDir\bin"
$LogsDir = "$BaseDir\logs"
$serviceName = "MediaServerRust"

# Ensure directories exist
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }

# 1. Ensure PostgreSQL is running
$pgConn = Get-NetTCPConnection -LocalPort 5432 -ErrorAction SilentlyContinue
if (-not $pgConn) {
    Write-Host "[1/5] PostgreSQL is not running. Starting PostgreSQL..." -ForegroundColor Yellow
    & "$BaseDir\scripts\start_postgres.bat"
    Start-Sleep -Seconds 2
} else {
    Write-Host "[1/5] PostgreSQL is active on port 5432." -ForegroundColor Green
}

# 2. Check if MediaServerRust is installed as Windows Service
$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($svc) {
    # Check admin privilege for service restart
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Elevated Administrator privileges are required to restart Windows Service '$serviceName'." -ForegroundColor Yellow
        powershell -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File `\"$PSCommandPath`\"' -WorkingDirectory '$BaseDir' -Verb RunAs"
        exit 0
    }

    Write-Host "[2/5] Stopping '$serviceName' service..." -ForegroundColor Yellow
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue

    # Wait for the binary to be released before building, and fail loudly if
    # it never is - a stale binary that looks like a successful deploy is the
    # worst possible outcome here.
    $released = Wait-BinaryReleased -ProcessName "media-server-api"
    if (-not $released) {
        Write-Host "  media-server-api.exe is still locked after 60s." -ForegroundColor Red
    } else {
        Write-Host "  Binary released by NSSM." -ForegroundColor DarkGray
    }

    # Optional Rebuild while service is stopped
    if (-not $NoRebuild) {
        Write-Host "[3/5] Compiling latest Rust release binary..." -ForegroundColor Yellow
        & "$BaseDir\scripts\cargo.bat" build --release --manifest-path "$RustDir\Cargo.toml"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "BUILD FAILED - the service is about to start the PREVIOUS binary." -ForegroundColor Red
            Write-Host "This restart did NOT deploy the current source. Re-run once the build error is fixed." -ForegroundColor Red
        }
    } else {
        Write-Host "[3/5] Skipping rebuild (--NoRebuild specified)." -ForegroundColor DarkGray
    }

    Write-Host "[4/5] Starting '$serviceName' service..." -ForegroundColor Cyan
    Start-Service -Name $serviceName
    Start-Sleep -Seconds 2

    $updatedSvc = Get-Service -Name $serviceName
    Write-Host "  Service Status: $($updatedSvc.Status)" -ForegroundColor Green

} else {
    Write-Host "[2/5] '$serviceName' Windows Service is not installed. Running in standalone mode." -ForegroundColor Yellow

    # Terminate any existing process on port 8001
    $connections = Get-NetTCPConnection -LocalPort 8001 -ErrorAction SilentlyContinue
    if ($connections) {
        $pids = $connections | Select-Object -ExpandProperty OwningProcess -Unique
        foreach ($p in $pids) {
            if ($p -gt 4) {
                Write-Host "  Stopping existing process on port 8001 (PID: $p)..." -ForegroundColor Yellow
                Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Get-Process -Name "media-server-api" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    # Rebuild if requested
    if (-not $NoRebuild) {
        Write-Host "[3/5] Compiling latest Rust binary..." -ForegroundColor Yellow
        & "$BaseDir\scripts\cargo.bat" build --release --manifest-path "$RustDir\Cargo.toml"
    }

    $releaseExe = "$RustDir\target\release\media-server-api.exe"
    $debugExe = "$RustDir\target\debug\media-server-api.exe"
    $exePath = if (Test-Path $releaseExe) { $releaseExe } else { $debugExe }

    Write-Host "[4/5] Launching standalone $exePath..." -ForegroundColor Cyan
    $env:MEDIA_SERVER_DATABASE_URL = "postgresql://postgres:postgres@127.0.0.1:5432/media_server"
    $env:RUST_HOST = "0.0.0.0"
    $env:RUST_PORT = "8001"
    $env:MEDIA_SERVER_MEDIA_ROOT = "D:\Flicks"
    $env:MEDIA_SERVER_CACHE_DIR = "E:\MediaServer\cache"
    $env:MEDIA_SERVER_STATIC_DIR = "E:\MediaServer\web\dist"
    $env:RUST_LOG = "info"

    $logOut = "$LogsDir\rust_api.log"
    $logErr = "$LogsDir\rust_api_error.log"
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"`"$exePath`" >> `"$logOut`" 2>> `"$logErr`"`"" -WorkingDirectory $BaseDir -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

# 5. Probes & Health Check
Write-Host "[5/5] Testing HTTP Endpoints on Port 8001..." -ForegroundColor Yellow

try {
    $spaRes = Invoke-WebRequest -Uri "http://127.0.0.1:8001/" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Local SPA (http://127.0.0.1:8001/): $($spaRes.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Local SPA Error: $_" -ForegroundColor Red
}

try {
    $apiRes = Invoke-WebRequest -Uri "http://127.0.0.1:8001/api/movies" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Local API (http://127.0.0.1:8001/api/movies): $($apiRes.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Local API Error: $_" -ForegroundColor Red
}

Write-Host "`nService restarted and healthy!" -ForegroundColor Green
