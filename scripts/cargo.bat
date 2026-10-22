@echo off
set "MSVC_BIN=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.50.35717\bin\Hostx64\x64"
set "MSVC_LIB=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.50.35717\lib\x64"
set "MSVC_INC=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.50.35717\include"
set "WIN_SDK_UM=D:\WindowsKits\10\lib\10.0.26100.0\um\x64"
set "WIN_SDK_UCRT=D:\WindowsKits\10\lib\10.0.26100.0\ucrt\x64"
set "WIN_SDK_INC_UM=D:\WindowsKits\10\Include\10.0.26100.0\um"
set "WIN_SDK_INC_UCRT=D:\WindowsKits\10\Include\10.0.26100.0\ucrt"
set "WIN_SDK_INC_SHARED=D:\WindowsKits\10\Include\10.0.26100.0\shared"
set "CARGO_BIN=C:\Users\anis7\.cargo\bin"

set "PATH=%MSVC_BIN%;%CARGO_BIN%;%PATH%"
set "LIB=%MSVC_LIB%;%WIN_SDK_UM%;%WIN_SDK_UCRT%;%LIB%"
rem INCLUDE is what pure-Rust builds never need, so it was never set - and any
rem crate with C sources (ring, aws-lc-sys, and so any rustls crypto provider)
rem then fails to find stddef.h. Symptom is "cl.exe ran and returned exit 2".
set "INCLUDE=%MSVC_INC%;%WIN_SDK_INC_UCRT%;%WIN_SDK_INC_UM%;%WIN_SDK_INC_SHARED%"

cargo %*
