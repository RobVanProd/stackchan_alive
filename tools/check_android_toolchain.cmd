@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_android_toolchain.ps1" %*
