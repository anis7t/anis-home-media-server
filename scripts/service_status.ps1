# Authoritative diagnostic script to check MediaServer (Rust/Axum), PostgreSQL, Cloudflared tunnel, and HTTP endpoints.

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         Media Server & Tunnel Health Check         " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Services Status
Write-Host "`n[1/5] Windows Services Status:" -ForegroundColor Yellow
$services = Get-Service -Name "MediaServerRust", "MediaServerPG", "Cloudflared" -ErrorAction SilentlyContinue
if ($services) {
    $services | Format-Table -AutoSize Name, DisplayName, Status, StartType
} else {
    Write-Host "  No MediaServer services were found." -ForegroundColor Red
}

# 2. Port Listeners Check
Write-Host "[2/5] Port Listeners Check:" -ForegroundColor Yellow

# Port 8000 (Rust Primary)
$conn8000 = Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn8000) {
    $proc8000 = Get-Process -Id $conn8000.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Rust/Axum (Port 8000): Listening by $($proc8000.ProcessName) (PID: $($proc8000.Id), RAM: $([math]::Round($proc8000.WorkingSet64/1MB, 1)) MB)" -ForegroundColor Green
} else {
    Write-Host "  Rust/Axum (Port 8000): NOT listening." -ForegroundColor Red
}

# Port 5432 (PostgreSQL)
$conn5432 = Get-NetTCPConnection -LocalPort 5432 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn5432) {
    $proc5432 = Get-Process -Id $conn5432.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Postgres  (Port 5432): Listening by $($proc5432.ProcessName) (PID: $($proc5432.Id))" -ForegroundColor Green
} else {
    Write-Host "  Postgres  (Port 5432): NOT listening." -ForegroundColor Red
}

# Port 8001 (Retired)
$conn8001 = Get-NetTCPConnection -LocalPort 8001 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn8001) {
    $proc8001 = Get-Process -Id $conn8001.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Warning: Port 8001 is listening by $($proc8001.ProcessName) (should be released)." -ForegroundColor DarkYellow
} else {
    Write-Host "  Port 8001 (Retired): Correctly closed/released." -ForegroundColor DarkGray
}

# 3. HTTP Probes
Write-Host "`n[3/5] HTTP Connectivity Tests:" -ForegroundColor Yellow

# Local Health Probe
try {
    $resHealth = Invoke-RestMethod -Uri "http://127.0.0.1:8000/health" -TimeoutSec 4
    Write-Host "  Local Health  (http://127.0.0.1:8000/health): OK [Engine: $($resHealth.engine), Status: $($resHealth.status)]" -ForegroundColor Green
} catch {
    Write-Host "  Local Health Error: $_" -ForegroundColor Red
}

# Local SPA Probe
try {
    $resLocal = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Local SPA     (http://127.0.0.1:8000/): $($resLocal.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Local SPA Error: $_" -ForegroundColor Red
}

# Local API Probe
try {
    $resApi = Invoke-WebRequest -Uri "http://127.0.0.1:8000/api/movies" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Local API     (http://127.0.0.1:8000/api/movies): $($resApi.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Local API Error: $_" -ForegroundColor Red
}

# Cloudflare Ingress Probe
try {
    $resPublic = Invoke-RestMethod -Uri "https://media.anisparvez.in/health" -TimeoutSec 6
    Write-Host "  Public Tunnel (https://media.anisparvez.in/health): OK [Engine: $($resPublic.engine)]" -ForegroundColor Green
} catch {
    Write-Host "  Public Tunnel Error: $_" -ForegroundColor Red
}

# 4. Active Transcode Telemetry
Write-Host "`n[4/5] Active Transcodes & Queue:" -ForegroundColor Yellow
try {
    $trans = Invoke-RestMethod -Uri "http://127.0.0.1:8000/api/transcodes" -TimeoutSec 4
    $count = if ($trans.transcodes) { $trans.transcodes.Count } else { 0 }
    Write-Host "  Active Hardware Transcodes: $count" -ForegroundColor Cyan
} catch {
    Write-Host "  Unable to fetch transcode telemetry: $_" -ForegroundColor DarkGray
}

# 5. Recent Log Tails
Write-Host "`n[5/5] Recent Log Tails:" -ForegroundColor Yellow
$rustLog = "E:\MediaServer\logs\rust_api.log"
$rustErr = "E:\MediaServer\logs\rust_api_error.log"

if (Test-Path $rustLog) {
    Write-Host "--- Last 5 lines of logs\rust_api.log ---" -ForegroundColor DarkGray
    Get-Content $rustLog -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}
if ((Test-Path $rustErr) -and (Get-Item $rustErr).Length -gt 0) {
    Write-Host "--- Last 5 lines of logs\rust_api_error.log ---" -ForegroundColor DarkYellow
    Get-Content $rustErr -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}
