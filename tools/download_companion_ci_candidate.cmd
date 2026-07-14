@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0download_companion_ci_candidate.ps1" %*
