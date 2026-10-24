@echo off
title Media Server - PostgreSQL Backup
echo ====================================================
echo             PostgreSQL Database Backup              
echo ====================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_postgres.ps1" %*
echo.
pause
