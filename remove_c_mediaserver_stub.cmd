@echo off
setlocal EnableExtensions
title Remove stale C:\MediaServer stub - needs Administrator

rem ---------------------------------------------------------------
rem  Self-elevating: double-click, or run the path from any shell.
rem  Deletes ONLY C:\MediaServer once it contains just .pytest_cache.
rem ---------------------------------------------------------------

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting Administrator rights - approve the UAC prompt...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

cd /d "%~dp0"
set "ROOT=C:\MediaServer"
set "LISTFILE=%~dp0ms_stub_list.txt"

echo ============================================================
echo  Remove stale C:\MediaServer   [running elevated]
echo ============================================================
echo.

echo --- pre-flight ---
if not exist "%ROOT%" (
  echo [SKIP] %ROOT% does not exist - nothing to do.
  goto :done
)

dir /b /a "%ROOT%" >"%LISTFILE%" 2>nul
if errorlevel 1 (
  echo [ABORT] cannot enumerate %ROOT% - fix access first.
  del "%LISTFILE%" >nul 2>nul
  goto :fail
)

set "UNEXPECTED="
for /f "usebackq delims=" %%A in ("%LISTFILE%") do (
  if /i not "%%A"==".pytest_cache" set "UNEXPECTED=%%A"
)
del "%LISTFILE%" >nul 2>nul

if defined UNEXPECTED (
  echo [ABORT] unexpected entry: %UNEXPECTED%
  echo         %ROOT% is not the empty stub - refusing to delete it.
  goto :fail
)
echo       ok: only .pytest_cache is present

sc qc MediaServer | findstr /i /c:"C:\MediaServer" >nul
if not errorlevel 1 (
  echo [ABORT] the MediaServer service still refers to C:\MediaServer.
  goto :fail
)
echo       ok: service binPath is not on C:

echo.
echo --- take ownership and reset ACLs ---
takeown /f "%ROOT%" /r /d y
icacls  "%ROOT%" /reset /t /c /q

echo.
echo --- delete ---
rmdir /s /q "%ROOT%"
if exist "%ROOT%" (
  echo       rmdir was refused - granting rights once more and retrying
  icacls "%ROOT%" /grant "*S-1-5-32-544:(F)" /t /c /q
  icacls "%ROOT%" /inheritance:e /t /c /q
  takeown /f "%ROOT%" /r /d y >nul
  rmdir /s /q "%ROOT%"
)

:done
if exist "%ROOT%" (
  echo.
  echo [FAIL] %ROOT% still exists.
  goto :fail
)
echo [OK] %ROOT% removed.
echo.
echo --- result ---
dir /a "C:\" | findstr /i /c:"MediaServer" || echo       no MediaServer entry under C:\
powershell -NoProfile -Command "$d=Get-PSDrive C; 'C: free {0:N1} GB of {1:N1} GB' -f ($d.Free/1GB), (($d.Free+$d.Used)/1GB)"
echo.
pause
exit /b 0

:fail
echo.
echo Script stopped - nothing beyond %ROOT% was touched.
pause
exit /b 1