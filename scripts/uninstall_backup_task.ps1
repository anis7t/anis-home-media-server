# Remove the "MediaServerBackup" Scheduled Task.
# Run this script with Administrator privileges (it auto-prompts if not elevated).

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevated Administrator privileges are required to remove a Scheduled Task." -ForegroundColor Yellow
    if (Get-Command sudo.exe -ErrorAction SilentlyContinue) {
        sudo.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath"
        exit $LASTEXITCODE
    } else {
        Write-Host "Please run this script from an elevated PowerShell window (Run as Administrator)." -ForegroundColor Red
        exit 1
    }
}

$TaskName = "MediaServerBackup"

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "The '$TaskName' task is not registered. Nothing to do." -ForegroundColor Yellow
    exit 0
}

Write-Host "Removing the '$TaskName' task..." -ForegroundColor Yellow
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Removed. Existing archives in the backup store are untouched." -ForegroundColor Green
exit 0
