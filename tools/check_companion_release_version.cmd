@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_companion_release_version.ps1" %*
