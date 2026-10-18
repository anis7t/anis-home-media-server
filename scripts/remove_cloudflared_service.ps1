# Elevated PowerShell script to stop and decommission the Cloudflared Windows Service

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "       Decommissioning Cloudflared Windows Service   " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$svc = Get-Service -Name "Cloudflared" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "`nStopping Cloudflared service..." -ForegroundColor Yellow
    Stop-Service -Name "Cloudflared" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Host "Removing Cloudflared Windows service registration..." -ForegroundColor Yellow
    & sc.exe delete "Cloudflared"
    Start-Sleep -Seconds 1

    $verify = Get-Service -Name "Cloudflared" -ErrorAction SilentlyContinue
    if (-not $verify) {
        Write-Host "`n[SUCCESS] Cloudflared Windows Service was successfully removed." -ForegroundColor Green
    } else {
        Write-Host "`n[WARNING] Service still present. Disabling startup..." -ForegroundColor DarkYellow
        Set-Service -Name "Cloudflared" -StartupType Disabled -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "`n[INFO] Cloudflared service is not registered on this system." -ForegroundColor Green
}
