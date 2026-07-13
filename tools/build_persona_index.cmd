@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_persona_index.ps1" %*
