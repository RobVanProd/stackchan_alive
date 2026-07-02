@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0export_rvc_voice_base_status.ps1" %*
