@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload_lan_ota.ps1" %*
