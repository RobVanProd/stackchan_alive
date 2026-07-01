@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0share_release.ps1" %*
