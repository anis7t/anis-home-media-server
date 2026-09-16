@echo off
title Media Server - Service Restarter
echo ====================================================
echo             Restarting Media Server Service         
echo ====================================================
echo.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Restart-Service -Name MediaServer; Start-Sleep -Seconds 2; Write-Host 'Service Restarted!' -ForegroundColor Green"
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0service_status.ps1"
echo.
pause

