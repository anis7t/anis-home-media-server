@echo off
title Media Server - Rust Service Restarter
echo ====================================================
echo             Restarting MediaServerRust             
echo ====================================================
echo.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -WorkingDirectory '%~dp0..' -Verb RunAs"
    exit /b
)

:: Run the PowerShell restart script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart_rust_service.ps1"
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0rust_service_status.ps1"
echo.
pause
