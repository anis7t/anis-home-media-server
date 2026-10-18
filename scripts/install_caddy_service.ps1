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

# 2. NSSM Service Registration
Write-Host ""
Write-Host "[2/3] Registering MediaServerCaddy Service via NSSM..." -ForegroundColor Yellow
$nssm = "E:\MediaServer\bin\nssm.exe"
$caddyExe = "E:\MediaServer\bin\caddy_custom.exe"
if (-not (Test-Path $caddyExe)) {
    $caddyExe = "E:\MediaServer\bin\caddy.exe"
}
$caddyfile = "E:\MediaServer\Caddyfile"
$appDir = "E:\MediaServer"
$serviceName = "MediaServerCaddy"

$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if (-not $existing) {
    & $nssm install $serviceName $caddyExe "run --config $caddyfile"
    & $nssm set $serviceName AppDirectory $appDir
    & $nssm set $serviceName Description "Caddy Reverse Proxy for Anis Media Server (HTTPS :443 -> :8000)"
    & $nssm set $serviceName Start SERVICE_AUTO_START
    & $nssm set $serviceName AppStdout "E:\MediaServer\logs\caddy.log"
    & $nssm set $serviceName AppStderr "E:\MediaServer\logs\caddy_error.log"
    & $nssm set $serviceName AppRotateFiles 1
    & $nssm set $serviceName AppRotateBytes 10485760
    Write-Host "  [+] Installed $serviceName as an Automatic Windows Service" -ForegroundColor Green
} else {
    Write-Host "  [*] Service $serviceName already installed, updating configuration..." -ForegroundColor Gray
    & $nssm set $serviceName Application $caddyExe
    & $nssm set $serviceName AppParameters "run --config $caddyfile"
    & $nssm set $serviceName AppDirectory $appDir
    & $nssm set $serviceName AppStdout "E:\MediaServer\logs\caddy.log"
    & $nssm set $serviceName AppStderr "E:\MediaServer\logs\caddy_error.log"
}

# 3. Start or Restart Service
Write-Host ""
Write-Host "[3/3] Starting MediaServerCaddy Service..." -ForegroundColor Yellow
Restart-Service -Name $serviceName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$svc = Get-Service -Name $serviceName
if ($svc.Status -eq "Running") {
    Write-Host "  [SUCCESS] $serviceName is RUNNING!" -ForegroundColor Green
} else {
    Write-Host "  [WARNING] $serviceName status: $($svc.Status)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Cyan
