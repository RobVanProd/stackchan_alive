@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0package_release.ps1" %*
