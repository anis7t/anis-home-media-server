# Quick diagnostic script to check MediaServer and Cloudflared services, logs, and HTTP endpoints.

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         Media Server & Tunnel Health Check         " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Services Status
Write-Host "`n[1/4] Windows Services Status:" -ForegroundColor Yellow
$services = Get-Service -Name "MediaServer", "MediaServerRust", "Cloudflared" -ErrorAction SilentlyContinue
if ($services) {
    $services | Format-Table -AutoSize Name, DisplayName, Status, StartType
} else {
    Write-Host "None of MediaServer, MediaServerRust, or Cloudflared services were found." -ForegroundColor Red
}

# 2. Port Listeners Check
Write-Host "[2/4] Port Listeners Check:" -ForegroundColor Yellow
$conn8000 = Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn8000) {
    $proc8000 = Get-Process -Id $conn8000.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Flask   (Port 8000): Listening by $($proc8000.ProcessName) (PID: $($proc8000.Id), RAM: $([math]::Round($proc8000.WorkingSet64/1MB, 1)) MB)" -ForegroundColor Green
} else {
    Write-Host "  Flask   (Port 8000): NOT listening." -ForegroundColor Red
}

$conn8001 = Get-NetTCPConnection -LocalPort 8001 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn8001) {
    $proc8001 = Get-Process -Id $conn8001.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "  Rust    (Port 8001): Listening by $($proc8001.ProcessName) (PID: $($proc8001.Id), RAM: $([math]::Round($proc8001.WorkingSet64/1MB, 1)) MB)" -ForegroundColor Green
} else {
    Write-Host "  Rust    (Port 8001): NOT listening." -ForegroundColor DarkGray
}

# 3. HTTP Probes
Write-Host "`n[3/4] HTTP Connectivity Tests:" -ForegroundColor Yellow
try {
    $resLocal = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Flask Local Origin (http://127.0.0.1:8000/): $($resLocal.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Flask Local Origin Error: $_" -ForegroundColor Red
}

try {
    $resRust = Invoke-WebRequest -Uri "http://127.0.0.1:8001/" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Rust SPA Origin    (http://127.0.0.1:8001/): $($resRust.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Rust SPA Origin Warning: $_" -ForegroundColor DarkGray
}

try {
    $req = [System.Net.HttpWebRequest]::Create("https://media.anisparvez.in/")
    $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    $req.Timeout = 6000
    $resPublic = $req.GetResponse()
    Write-Host "  Public Tunnel      (https://media.anisparvez.in/): $($resPublic.StatusCode) OK" -ForegroundColor Green
    $resPublic.Close()
} catch {
    Write-Host "  Public Tunnel Error: $_" -ForegroundColor Red
}

# 4. Recent Logs
Write-Host "`n[4/4] Recent Log Tails:" -ForegroundColor Yellow
$waitressLog = "E:\MediaServer\logs\waitress.log"
$waitressErr = "E:\MediaServer\logs\waitress_error.log"

if (Test-Path $waitressLog) {
    Write-Host "--- Last 5 lines of waitress.log ---" -ForegroundColor DarkGray
    Get-Content $waitressLog -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}
if ((Test-Path $waitressErr) -and (Get-Item $waitressErr).Length -gt 0) {
    Write-Host "--- Last 5 lines of waitress_error.log ---" -ForegroundColor DarkYellow
    Get-Content $waitressErr -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}

