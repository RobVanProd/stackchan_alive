@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0send_stackchan_serial_command.ps1" %*
