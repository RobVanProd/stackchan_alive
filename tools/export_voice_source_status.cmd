@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0export_voice_source_status.ps1" %*
