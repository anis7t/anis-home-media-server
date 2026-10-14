@echo off
setlocal
echo ====================================================
echo   Media Server PostgreSQL 18.4 Starter
echo ====================================================

set "PG_BIN=E:\postgres\pgsql\bin"
set "PG_DATA=E:\pgdata"

if not exist "%PG_BIN%\pg_ctl.exe" (
    echo [ERROR] PostgreSQL binaries not found at %PG_BIN%
    exit /b 1
)

if not exist "%PG_DATA%\PG_VERSION" (
    echo [ERROR] PostgreSQL data directory not found at %PG_DATA%
    exit /b 1
)

"%PG_BIN%\pg_ctl.exe" status -D "%PG_DATA%" >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [INFO] PostgreSQL is already running.
    exit /b 0
)

echo [INFO] Starting PostgreSQL cluster from %PG_DATA%...
"%PG_BIN%\pg_ctl.exe" -D "%PG_DATA%" -l "%PG_DATA%\pg.log" start

timeout /t 2 /nobreak >nul
"%PG_BIN%\pg_ctl.exe" status -D "%PG_DATA%"
if %ERRORLEVEL% equ 0 (
    echo [OK] PostgreSQL started successfully.
    exit /b 0
) else (
    echo [ERROR] Failed to start PostgreSQL. Check %PG_DATA%\pg.log
    exit /b 1
)
