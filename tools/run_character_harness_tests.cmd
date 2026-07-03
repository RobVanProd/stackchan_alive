@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_character_harness_tests.ps1" %*
