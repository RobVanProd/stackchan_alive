@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_desktop_release_signing_readiness.ps1" %*
