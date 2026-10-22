# Register the "MediaServerBackup" Scheduled Task so the PostgreSQL backup runs
# unattended. Run this script with Administrator privileges (it auto-prompts if
# not elevated).
#
# Why a task and not just the script:
#   Nothing on this host ran backup_postgres.ps1 automatically. The archives in
#   the backup store were taken by hand, which means a restore is only ever as
#   good as the last manual run. This closes that gap.
#
# The task calls run_backup_task.bat rather than backup_postgres.bat, because
# the latter ends with a `pause` that would hang a non-interactive run.

$ErrorActionPreference = "Stop"

# 1. Ensure Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevated Administrator privileges are required to register a Scheduled Task." -ForegroundColor Yellow
    if (Get-Command sudo.exe -ErrorAction SilentlyContinue) {
        Write-Host "Launching elevated session via Windows sudo..." -ForegroundColor Cyan
        sudo.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath"
        exit $LASTEXITCODE
    } else {
        Write-Host "Please run this script from an elevated PowerShell window (Run as Administrator)." -ForegroundColor Red
        exit 1
    }
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "   Installing the PostgreSQL Backup Scheduled Task  " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$TaskName    = "MediaServerBackup"
$BaseDir     = "E:\MediaServer"
$Runner      = "$BaseDir\scripts\run_backup_task.bat"
$BackupScript= "$BaseDir\scripts\backup_postgres.ps1"
$DestDir     = "$BaseDir\backups\postgres"
$LogsDir     = "$BaseDir\logs"
$At          = "03:00"

# 2. Preconditions
foreach ($p in @($Runner, $BackupScript)) {
    if (-not (Test-Path $p)) {
        Write-Host "ERROR: required script not found: $p" -ForegroundColor Red
        exit 1
    }
}
foreach ($d in @($DestDir, $LogsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$pgConn = Get-NetTCPConnection -LocalPort 5432 -ErrorAction SilentlyContinue
if (-not $pgConn) {
    Write-Host "WARNING: PostgreSQL is not listening on port 5432. The task will" -ForegroundColor Yellow
    Write-Host "         fail until MediaServerPG is running." -ForegroundColor Yellow
} else {
    Write-Host "PostgreSQL is active on port 5432." -ForegroundColor Green
}

# 3. Remove any previous registration so this is idempotent
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing the existing '$TaskName' task..." -ForegroundColor DarkGray
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# 4. Register
$action = New-ScheduledTaskAction -Execute $Runner -WorkingDirectory $BaseDir

$trigger = New-ScheduledTaskTrigger -Daily -At $At

# StartWhenAvailable: if the machine was off at 03:00 the run happens at the
# next opportunity instead of being skipped silently.
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Daily PostgreSQL backup of the media_server database via pg_dump -Fc. Logs to $LogsDir\backup_postgres.log." | Out-Null

Write-Host "Registered '$TaskName'." -ForegroundColor Green

# 5. Verify the registration
$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "  Action    : $($task.Actions[0].Execute) $($task.Actions[0].Arguments)" -ForegroundColor DarkGray
Write-Host "  Trigger   : daily at $At" -ForegroundColor DarkGray
Write-Host "  Runs as   : $($task.Principal.UserId)" -ForegroundColor DarkGray
Write-Host "  Next run  : $($info.NextRunTime)" -ForegroundColor DarkGray
Write-Host "  Last run  : $($info.LastRunTime) (result $($info.LastTaskResult))" -ForegroundColor DarkGray

Write-Host "`nTo run it now:  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
Write-Host "To remove it  :  scripts\uninstall_backup_task.ps1" -ForegroundColor Cyan
Write-Host "`nScheduled backup installation complete." -ForegroundColor Green
exit 0
