@echo off
setlocal
cd /d "%~dp0\.."

echo ====================================================
echo   Media Server Database Backup
echo ====================================================

if exist "venv\Scripts\python.exe" (
    venv\Scripts\python.exe scripts\backup_database.py --label scheduled-task --keep 14
) else (
    python scripts\backup_database.py --label scheduled-task --keep 14
)

if %ERRORLEVEL% equ 0 (
    echo [OK] Backup completed successfully.
) else (
    echo [FAIL] Backup failed with exit code %ERRORLEVEL%.
)
exit /b %ERRORLEVEL%
