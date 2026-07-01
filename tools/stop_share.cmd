@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop_share.ps1" %*
