@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_device_preflight.ps1" %*
