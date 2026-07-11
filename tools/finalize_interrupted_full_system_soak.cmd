@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0finalize_interrupted_full_system_soak.ps1" %*
