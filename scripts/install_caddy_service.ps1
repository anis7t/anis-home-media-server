# E:\MediaServer\scripts\install_caddy_service.ps1
# Configures Windows Firewall and registers MediaServerCaddy via NSSM
$ErrorActionPreference = "Stop"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "       MediaServerCaddy Service Installation        " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Windows Firewall Rules
Write-Host "[1/3] Configuring Inbound Windows Firewall Rules..." -ForegroundColor Yellow
$rule443 = Get-NetFirewallRule -DisplayName "Media Server HTTPS (Port 443)" -ErrorAction SilentlyContinue
if (-not $rule443) {
    New-NetFirewallRule -DisplayName "Media Server HTTPS (Port 443)" -Direction Inbound -LocalPort 443 -Protocol TCP -Action Allow | Out-Null
    Write-Host "  [+] Added Inbound Rule: Port 443 (HTTPS)" -ForegroundColor Green
} else {
    Write-Host "  [*] Port 443 Rule already exists" -ForegroundColor Gray
}

$rule80 = Get-NetFirewallRule -DisplayName "Media Server HTTP (Port 80)" -ErrorAction SilentlyContinue
if (-not $rule80) {
    New-NetFirewallRule -DisplayName "Media Server HTTP (Port 80)" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow | Out-Null
    Write-Host "  [+] Added Inbound Rule: Port 80 (HTTP redirect)" -ForegroundColor Green
} else {
    Write-Host "  [*] Port 80 Rule already exists" -ForegroundColor Gray
}

# 2. NSSM Service Registration & C: Drive Resilience
Write-Host ""
Write-Host "[2/3] Registering MediaServerCaddy Service via NSSM on C:\..." -ForegroundColor Yellow

# Internal drive C: paths for resilience against USB E: disconnects
$cRoot = "C:\MediaServer"
$cBin = "$cRoot\bin"
$cLogs = "$cRoot\logs"
if (-not (Test-Path $cBin)) { New-Item -ItemType Directory -Path $cBin -Force | Out-Null }
if (-not (Test-Path $cLogs)) { New-Item -ItemType Directory -Path $cLogs -Force | Out-Null }

$nssm = "$cBin\nssm.exe"
if (-not (Test-Path $nssm)) {
    if (Test-Path "E:\MediaServer\bin\nssm.exe") {
        Copy-Item "E:\MediaServer\bin\nssm.exe" $nssm -Force
    } else {
        $nssm = "E:\MediaServer\bin\nssm.exe"
    }
}

$serviceName = "MediaServerCaddy"
$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existing -and $existing.Status -eq 'Running') {
    Write-Host "  [*] Stopping running $serviceName service to allow binary update..." -ForegroundColor Yellow
    Stop-Service $serviceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$sourceCaddy = "E:\MediaServer\bin\caddy_custom.exe"
if (-not (Test-Path $sourceCaddy)) {
    $sourceCaddy = "E:\MediaServer\bin\caddy.exe"
}
$targetCaddy = "$cBin\caddy_custom.exe"
Copy-Item $sourceCaddy $targetCaddy -Force

$sourceCaddyfile = "E:\MediaServer\Caddyfile"
$targetCaddyfile = "$cRoot\Caddyfile"
Copy-Item $sourceCaddyfile $targetCaddyfile -Force

if (-not $existing) {
    & $nssm install $serviceName $targetCaddy "run --config $targetCaddyfile"
}

# Ensure the Windows service wrapper executable itself is hosted on C:
sc.exe config $serviceName binpath= $nssm | Out-Null

# Configure service parameters pointing to resilient C:\ drive
& $nssm set $serviceName Application $targetCaddy
& $nssm set $serviceName AppParameters "run --config $targetCaddyfile"
& $nssm set $serviceName AppDirectory $cRoot
& $nssm set $serviceName DisplayName "MediaServerCaddy"
& $nssm set $serviceName Description "Caddy Reverse Proxy for Anis Media Server (HTTPS :443 -> :8000)"
& $nssm set $serviceName Start SERVICE_AUTO_START
& $nssm set $serviceName AppStdout "$cLogs\caddy.log"
& $nssm set $serviceName AppStderr "$cLogs\caddy_error.log"
& $nssm set $serviceName AppRotateFiles 1
& $nssm set $serviceName AppRotateOnline 1
& $nssm set $serviceName AppRotateSeconds 86400
& $nssm set $serviceName AppRotateBytes 10485760
& $nssm set $serviceName AppRestartDelay 5000

# Windows Service Control Manager automatic crash recovery (5s delay, survives reboots)
sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/5000/restart/10000

# 3. Start or Restart Service
Write-Host ""
Write-Host "[3/3] Starting MediaServerCaddy Service..." -ForegroundColor Yellow
Restart-Service -Name $serviceName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$svc = Get-Service -Name $serviceName
if ($svc.Status -eq "Running") {
    Write-Host "  [SUCCESS] $serviceName is RUNNING from C:\ with auto-recovery!" -ForegroundColor Green
} else {
    Write-Host "  [WARNING] $serviceName status: $($svc.Status)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Cyan
