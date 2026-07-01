@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0export_github_actions_status.ps1" %*
