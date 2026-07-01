@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish_release.ps1" %*
