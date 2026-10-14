@echo off
set "MSVC_BIN=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.50.35717\bin\Hostx64\x64"
set "MSVC_LIB=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.50.35717\lib\x64"
set "WIN_SDK_UM=D:\WindowsKits\10\lib\10.0.26100.0\um\x64"
set "WIN_SDK_UCRT=D:\WindowsKits\10\lib\10.0.26100.0\ucrt\x64"

set "PATH=%MSVC_BIN%;%PATH%"
set "LIB=%MSVC_LIB%;%WIN_SDK_UM%;%WIN_SDK_UCRT%;%LIB%"

cargo %*
