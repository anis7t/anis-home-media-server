@echo off
:: Scheduled-task wrapper for the PostgreSQL backup.
::
:: Invoked by the "MediaServerBackup" Scheduled Task. It calls the PowerShell
:: script directly rather than backup_postgres.bat, because that .bat ends with
:: a `pause` that would hang a non-interactive scheduled run. Output is
:: appended to a log so a run can be audited without opening Task Scheduler,
:: and the exit code is propagated so Task Scheduler records a failure.
title Media Server - PostgreSQL Backup (scheduled)

set "LOGDIR=E:\MediaServer\logs"
set "LOGFILE=%LOGDIR%\backup_postgres.log"

if not exist "%LOGDIR%" mkdir "%LOGDIR%" 2>nul

echo [%DATE% %TIME%] Backup started. >> "%LOGFILE%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\MediaServer\scripts\backup_postgres.ps1" >> "%LOGFILE%" 2>&1
set "RC=%ERRORLEVEL%"

echo [%DATE% %TIME%] Backup finished with exit code %RC%. >> "%LOGFILE%"

exit /b %RC%
