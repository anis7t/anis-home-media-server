# Unregisters the MediaServerWatchdog scheduled task.
# Run elevated (install_watchdog.bat / install_watchdog.ps1 re-register it).
# The task runs an interactive PowerShell process every 5 minutes, which
# flashes a console window on the desktop. Making it invisible is a
# per-task setting (see below); this script removes it entirely.

$ErrorActionPreference = "Continue"
$Log = "C:\MediaServerLogs\install.log"
function L([string]$m) {
    $l = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    Write-Output $l
    Add-Content -Path $Log -Value $l -ErrorAction SilentlyContinue
}

$TaskName = "MediaServerWatchdog"
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $t) {
    L "task not present; nothing to do"
    exit 0
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
L "unregistered $TaskName"
exit 0