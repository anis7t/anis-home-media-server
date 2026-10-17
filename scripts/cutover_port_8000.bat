@echo off
title Media Server - Production Port 8000 Cutover
echo ====================================================
echo        Media Server - Production Port 8000 Cutover  
echo ====================================================
echo.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~f0' -WorkingDirectory '%~dp0..' -Verb RunAs"
    exit /b
)

:: Run the PowerShell cutover script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cutover_port_8000.ps1"
echo.
pause
