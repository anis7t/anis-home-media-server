@echo off
title Media Server - Remove Cloudflared Service
echo ====================================================
echo      Decommissioning Cloudflared Windows Service
echo ====================================================
echo.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator elevation...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0remove_cloudflared_service.ps1"
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0service_status.ps1"
echo.
pause
