@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare_device_arrival.ps1" %*
