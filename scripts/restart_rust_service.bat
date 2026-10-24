@echo off
title Media Server Rust - Service Restarter
echo ====================================================
echo         Restarting MediaServerRust Windows Service
echo ====================================================
echo.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator elevation...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart_rust_service.ps1"
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0service_status.ps1"
echo.
pause
