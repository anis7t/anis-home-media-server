# Authoritative diagnostic script to check MediaServer (Rust/Axum), PostgreSQL, Router Port Forwarding, and HTTP endpoints.

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         Media Server & Ingress Health Check        " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Services Status
Write-Host "`n[1/5] Windows Services Status:" -ForegroundColor Yellow
$services = Get-Service -Name "MediaServerRust", "MediaServerPG", "MediaServerCaddy" -ErrorAction SilentlyContinue
if ($services) {
    $services | Format-Table -AutoSize Name, DisplayName, Status, StartType
} else {
    Write-Host "  No MediaServer services were found." -ForegroundColor Red
}

$cfService = Get-Service -Name "Cloudflared" -ErrorAction SilentlyContinue
if ($cfService) {
    Write-Host "  Cloudflared service status: $($cfService.Status) (Decommissioning pending)" -ForegroundColor DarkYellow
} else {
    Write-Host "  Cloudflared service: Successfully decommissioned/removed." -ForegroundColor DarkGray
}

# 2. Port Listeners Check
Write-Host "[2/5] Port Listeners Check:" -ForegroundColor Yellow

# Port 8000 (Rust Primary)
$conn8000 = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn8000) {
    $proc8000 = Get-Process -Id $conn8000.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Rust/Axum (Port 8000): Listening by $($proc8000.ProcessName) (PID: $($proc8000.Id), RAM: $([math]::Round($proc8000.WorkingSet64/1MB, 1)) MB)" -ForegroundColor Green
} else {
    Write-Host "  Rust/Axum (Port 8000): NOT listening." -ForegroundColor Red
}

# Port 5432 (PostgreSQL)
$conn5432 = Get-NetTCPConnection -LocalPort 5432 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn5432) {
    $proc5432 = Get-Process -Id $conn5432.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Postgres  (Port 5432): Listening by $($proc5432.ProcessName) (PID: $($proc5432.Id))" -ForegroundColor Green
} else {
    Write-Host "  Postgres  (Port 5432): NOT listening." -ForegroundColor Red
}

# Port 8001 (Retired)
$conn8001 = Get-NetTCPConnection -LocalPort 8001 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn8001) {
    $proc8001 = Get-Process -Id $conn8001.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Warning: Port 8001 is listening by $($proc8001.ProcessName) (should be released)." -ForegroundColor DarkYellow
} else {
    Write-Host "  Port 8001 (Retired): Correctly closed/released." -ForegroundColor DarkGray
}

# Port 443 (Caddy HTTPS)
$conn443 = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn443) {
    $proc443 = Get-Process -Id $conn443.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Caddy     (Port 443) : Listening by $($proc443.ProcessName) (PID: $($proc443.Id))" -ForegroundColor Green
} else {
    Write-Host "  Caddy     (Port 443) : NOT listening." -ForegroundColor Red
}

# Port 80 (Caddy HTTP redirect)
$conn80 = Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn80) {
    Write-Host "  Caddy     (Port 80)  : Listening (HTTP -> HTTPS redirect)" -ForegroundColor Green
} else {
    Write-Host "  Caddy     (Port 80)  : NOT listening." -ForegroundColor DarkYellow
}

# 3. HTTP Probes
Write-Host "`n[3/5] HTTP Connectivity Tests:" -ForegroundColor Yellow

# Local Loopback Health Probe
try {
    $resHealth = Invoke-RestMethod -Uri "http://127.0.0.1:8000/health" -TimeoutSec 4
    Write-Host "  Local Loopback (http://127.0.0.1:8000/health): OK [Engine: $($resHealth.engine), Status: $($resHealth.status)]" -ForegroundColor Green
} catch {
    Write-Host "  Local Loopback Error: $_" -ForegroundColor Red
}

# Local LAN Ingress Probe (192.168.1.16)
try {
    $resLan = Invoke-RestMethod -Uri "http://192.168.1.16:8000/health" -TimeoutSec 4
    Write-Host "  LAN Ingress    (http://192.168.1.16:8000/health): OK [Engine: $($resLan.engine), Status: $($resLan.status)]" -ForegroundColor Green
} catch {
    Write-Host "  LAN Ingress Error: $_" -ForegroundColor Red
}

# Local SPA Probe
try {
    $resLocal = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Local SPA      (http://127.0.0.1:8000/): $($resLocal.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Local SPA Error: $_" -ForegroundColor Red
}

# Local API Probe
try {
    $resApi = Invoke-WebRequest -Uri "http://127.0.0.1:8000/api/movies" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Local API      (http://127.0.0.1:8000/api/movies): $($resApi.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Local API Error: $_" -ForegroundColor Red
}

# Domain HTTPS Probe (Port 443 - Standard Clean URL)
try {
    $resHttps = Invoke-RestMethod -Uri "https://media.anisparvez.in/health" -TimeoutSec 5
    Write-Host "  Domain HTTPS   (https://media.anisparvez.in/health): OK [TLS Valid, Engine: $($resHttps.engine)]" -ForegroundColor Green
} catch {
    Write-Host "  Domain HTTPS   (https://media.anisparvez.in/health): $_" -ForegroundColor DarkYellow
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
