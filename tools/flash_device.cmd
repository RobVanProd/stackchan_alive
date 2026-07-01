@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash_device.ps1" %*
