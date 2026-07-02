@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate_speech_envelope_sidecar.ps1" %*
