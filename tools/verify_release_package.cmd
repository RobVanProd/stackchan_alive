@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_release_package.ps1" %*
