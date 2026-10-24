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

:: Run the PowerShell restarter for MediaServerRust
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart_rust_service.ps1"
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0service_status.ps1"
echo.
pause
