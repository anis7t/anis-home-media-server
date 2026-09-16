# Quick diagnostic script to check MediaServer and Cloudflared services, logs, and HTTP endpoints.

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         Media Server & Tunnel Health Check         " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Services Status
Write-Host "`n[1/4] Windows Services Status:" -ForegroundColor Yellow
$services = Get-Service -Name "MediaServer", "Cloudflared" -ErrorAction SilentlyContinue
if ($services) {
    $services | Format-Table -AutoSize Name, DisplayName, Status, StartType
} else {
    Write-Host "Neither MediaServer nor Cloudflared service was found." -ForegroundColor Red
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
    $resLocal = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -UseBasicParsing -TimeoutSec 4
    Write-Host "  Local Origin (http://127.0.0.1:8000/): $($resLocal.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  Local Origin Error: $_" -ForegroundColor Red
}

try {
    $req = [System.Net.HttpWebRequest]::Create("https://media.anisparvez.in/")
    $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    $req.Timeout = 6000
    $resPublic = $req.GetResponse()
    Write-Host "  Public Tunnel (https://media.anisparvez.in/): $($resPublic.StatusCode) OK" -ForegroundColor Green
    $resPublic.Close()
} catch {
    Write-Host "  Public Tunnel Error: $_" -ForegroundColor Red
}

# 4. Recent Logs
Write-Host "`n[4/4] Recent Log Tails:" -ForegroundColor Yellow
$waitressLog = "C:\MediaServer\logs\waitress.log"
$waitressErr = "C:\MediaServer\logs\waitress_error.log"

if (Test-Path $waitressLog) {
    Write-Host "--- Last 5 lines of waitress.log ---" -ForegroundColor DarkGray
    Get-Content $waitressLog -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}
if ((Test-Path $waitressErr) -and (Get-Item $waitressErr).Length -gt 0) {
    Write-Host "--- Last 5 lines of waitress_error.log ---" -ForegroundColor DarkYellow
    Get-Content $waitressErr -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}

