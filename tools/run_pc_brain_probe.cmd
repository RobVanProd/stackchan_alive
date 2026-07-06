@echo off
python "%~dp0..\bridge\pc_brain_probe.py" %*
exit /b %ERRORLEVEL%
