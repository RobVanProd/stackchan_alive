@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_architecture.ps1" %*
