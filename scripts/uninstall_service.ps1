# Stop and remove the MediaServer Windows Service
# Run this script with Administrator privileges.

$ErrorActionPreference = "Stop"

# 1. Ensure Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevated Administrator privileges are required to remove Windows Services." -ForegroundColor Yellow
    if (Get-Command sudo.exe -ErrorAction SilentlyContinue) {
        Write-Host "Launching elevated session via Windows sudo..." -ForegroundColor Cyan
        sudo.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath"
        exit $LASTEXITCODE
    } else {
        Write-Host "Please run this script from an elevated PowerShell window (Run as Administrator)." -ForegroundColor Red
        exit 1
    }
}

$serviceName = "MediaServer"
$NssmExe = "C:\MediaServer\bin\nssm.exe"

Write-Host "Stopping $serviceName service..." -ForegroundColor Yellow
Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue

if (Test-Path $NssmExe) {
    Write-Host "Removing $serviceName via NSSM..." -ForegroundColor Yellow
    & $NssmExe remove $serviceName confirm
} else {
    Write-Host "Removing $serviceName via sc.exe..." -ForegroundColor Yellow
    sc.exe delete $serviceName
}

Write-Host "Service $serviceName has been removed." -ForegroundColor Green
