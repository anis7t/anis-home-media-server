@echo off
title Media Server - Caddy Restarter
echo ====================================================
echo             Restarting MediaServerCaddy Service      
echo ====================================================
echo.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo [1/2] Syncing Caddyfile from E:\MediaServer\Caddyfile to C:\MediaServer\Caddyfile...
copy /y "E:\MediaServer\Caddyfile" "C:\MediaServer\Caddyfile"

echo [2/2] Restarting MediaServerCaddy Windows Service...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Restart-Service -Name MediaServerCaddy; Start-Sleep -Seconds 2; Get-Service MediaServerCaddy"
echo.
echo Done. Press any key to close.
pause
