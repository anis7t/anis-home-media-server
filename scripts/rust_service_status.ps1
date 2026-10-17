# Quick diagnostic script to check MediaServerRust service, logs, and HTTP endpoints.

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         Media Server Rust Health Check             " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Services Status
Write-Host "`n[1/4] Windows Service Status:" -ForegroundColor Yellow
$svc = Get-Service -Name "MediaServerRust" -ErrorAction SilentlyContinue
if ($svc) {
    $svc | Format-Table -AutoSize Name, DisplayName, Status, StartType
} else {
    Write-Host "  MediaServerRust service is not installed (running standalone)." -ForegroundColor DarkGray
}

# 2. Port 8000 Listener Check
Write-Host "[2/4] Port 8000 Listener Check:" -ForegroundColor Yellow
$conn = Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn) {
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Port 8000 is listening by process: $($proc.ProcessName) (PID: $($proc.Id), Memory: $([math]::Round($proc.WorkingSet64/1MB, 1)) MB)" -ForegroundColor Green
} else {
    Write-Host "  Port 8000 is NOT listening." -ForegroundColor Red
}

# 3. HTTP Probes
Write-Host "`n[3/4] HTTP Connectivity Tests:" -ForegroundColor Yellow
try {
    $resSpa = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Local SPA (http://127.0.0.1:8000/): $($resSpa.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Local SPA Error: $_" -ForegroundColor Red
}

try {
    $resApi = Invoke-WebRequest -Uri "http://127.0.0.1:8000/api/movies" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Local API (http://127.0.0.1:8000/api/movies): $($resApi.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Local API Error: $_" -ForegroundColor Red
}

# 4. Recent Logs
Write-Host "`n[4/4] Recent Log Tails:" -ForegroundColor Yellow
$rustLog = "E:\MediaServer\logs\rust_api.log"
$rustErr = "E:\MediaServer\logs\rust_api_error.log"

if (Test-Path $rustLog) {
    Write-Host "--- Last 5 lines of rust_api.log ---" -ForegroundColor DarkGray
    Get-Content $rustLog -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}
if ((Test-Path $rustErr) -and (Get-Item $rustErr).Length -gt 0) {
    Write-Host "--- Last 5 lines of rust_api_error.log ---" -ForegroundColor DarkYellow
    Get-Content $rustErr -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}
