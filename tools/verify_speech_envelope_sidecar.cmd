@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_speech_envelope_sidecar.ps1" %*
