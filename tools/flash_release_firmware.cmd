@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash_release_firmware.ps1" %*
