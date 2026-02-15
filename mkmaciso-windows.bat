@echo off
REM Run mkmaciso Windows helper (PowerShell)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mkmaciso-windows.ps1" %*
pause
