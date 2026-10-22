@echo off
title Media Server - Install Caddy HTTPS Service
echo ====================================================
echo      Installing MediaServerCaddy Windows Service
echo ====================================================
echo.

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator elevation...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_caddy_service.ps1"
echo.
pause
