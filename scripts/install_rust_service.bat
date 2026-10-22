@echo off
title Media Server - Rust Windows Service Installer
echo ====================================================
echo  Installing MediaServerRust as a Windows Service
echo ====================================================
echo.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrative privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Run the PowerShell installer script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_rust_service.ps1"
echo.
pause
