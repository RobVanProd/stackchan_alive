@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0new_ci_account_block_exception.ps1" %*
