@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_full_online_physical_session_readiness.ps1" %*
