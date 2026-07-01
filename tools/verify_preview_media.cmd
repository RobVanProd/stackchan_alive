@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_preview_media.ps1" %*
