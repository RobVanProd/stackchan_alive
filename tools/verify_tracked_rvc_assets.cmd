@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_tracked_rvc_assets.ps1" %*
