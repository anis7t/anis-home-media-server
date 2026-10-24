@echo off
title Media Server - Phone Mirror (scrcpy)
echo Starting scrcpy mirror for 192.168.1.6:40307...
"C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages\Genymobile.scrcpy_Microsoft.Winget.Source_8wekyb3d8bbwe\scrcpy-win64-v4.1\scrcpy.exe" -s 192.168.1.6:40307 --stay-awake --window-title "Media Server Phone Live Mirror"
if errorlevel 1 (
    echo.
    echo Scrcpy exited with error. Trying fallback mDNS connection...
    "C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages\Genymobile.scrcpy_Microsoft.Winget.Source_8wekyb3d8bbwe\scrcpy-win64-v4.1\scrcpy.exe" --stay-awake --window-title "Media Server Phone Live Mirror"
)
pause
