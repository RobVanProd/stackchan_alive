@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0audit_published_release.ps1" %*
