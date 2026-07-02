@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_native_toolchain.ps1" %*
