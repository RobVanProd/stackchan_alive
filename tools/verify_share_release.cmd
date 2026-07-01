@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_share_release.ps1" %*
