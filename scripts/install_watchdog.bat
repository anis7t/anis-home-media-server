@echo off
:: Self-elevating installer for the MediaServerWatchdog scheduled task.
set "PS1=%~dp0install_watchdog.ps1"
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Requesting elevation...
    powershell -NoProfile -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%PS1%\"' -Verb RunAs"
    exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
pause
