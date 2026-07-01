@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_published_release.ps1" %*
