@echo off
setlocal
echo ====================================================
echo   Media Server PostgreSQL 18.4 Stopper
echo ====================================================

set "PG_BIN=E:\postgres\pgsql\bin"
set "PG_DATA=E:\pgdata"

if not exist "%PG_BIN%\pg_ctl.exe" (
    echo [ERROR] PostgreSQL binaries not found at %PG_BIN%
    exit /b 1
)

echo [INFO] Stopping PostgreSQL cluster at %PG_DATA%...
"%PG_BIN%\pg_ctl.exe" -D "%PG_DATA%" stop -m fast
if %ERRORLEVEL% equ 0 (
    echo [OK] PostgreSQL stopped cleanly.
    exit /b 0
) else (
    echo [WARN] pg_ctl stop returned exit code %ERRORLEVEL%.
    exit /b %ERRORLEVEL%
)
