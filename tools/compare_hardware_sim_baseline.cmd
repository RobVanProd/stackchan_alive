@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0compare_hardware_sim_baseline.ps1" %*
