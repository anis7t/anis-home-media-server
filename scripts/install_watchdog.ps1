# Registers the MediaServerWatchdog scheduled task.
# Must run elevated (the .bat wrapper handles the UAC prompt).
# Task: awais\anis7, highest privileges, at logon + every 5 min, idempotent.

$ErrorActionPreference = "Stop"

$InstallLog = "C:\MediaServerLogs\install.log"
function Write-InstallLog([string]$msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Write-Output $line
    Add-Content -Path $InstallLog -Value $line -ErrorAction SilentlyContinue
}

try {

$TaskName = "MediaServerWatchdog"
$Script = "E:\MediaServer\scripts\service_watchdog.ps1"
$User = "awais\anis7"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Administrator privileges required - run install_watchdog.bat" }

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Script`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description `
    "Keeps MediaServer, MediaServerRust and PostgreSQL alive across E: USB dropouts" | Out-Null

Write-InstallLog "Registered task $TaskName - starting first run..."
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 8
$info = Get-ScheduledTaskInfo -TaskName $TaskName
$info | Format-Table TaskName, LastRunTime, LastTaskResult -AutoSize | Out-String | ForEach-Object { Write-InstallLog $_.Trim() }
Write-InstallLog "INSTALL DONE result=$($info.LastTaskResult)"
} catch {
    Write-InstallLog "INSTALL FAILED: $($_.Exception.Message)"
    throw
} finally {
    Write-Output ""
    Read-Host "Press Enter to close this window"
}
