@echo off
title Media Server - Windows Service Uninstaller
echo ====================================================
echo  Removing MediaServer Windows Service
echo ====================================================
echo.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrative privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Run the PowerShell uninstaller script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall_service.ps1"
echo.
pause

