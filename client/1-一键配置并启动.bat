@echo off
cd /d "%~dp0"
echo ==========================================================
echo   RustDesk client - apply server settings and launch
echo ==========================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0set-server.ps1" -Silent
echo.
pause
