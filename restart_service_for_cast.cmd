@echo off
REM Reload the MediaServer service so it picks up the new /api/cast/* routes and the
REM updated player template (both are loaded once, at import time).
setlocal
echo Stopping MediaServer...
net stop MediaServer
echo.
echo Starting MediaServer...
net start MediaServer
echo.
echo Health check:
curl -s -o nul -w "  /            -> %%{http_code}\n" http://127.0.0.1:8000/
curl -s -o nul -w "  /api/cast/devices -> %%{http_code}\n" http://127.0.0.1:8000/api/cast/devices
echo.
echo Done. If both lines above show 200, casting is live.
pause