@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_companion_v1_readiness.ps1" %*
