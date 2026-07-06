@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_voice_source_readiness.ps1" %*
