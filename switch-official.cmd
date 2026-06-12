@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cc-codex-switch.ps1" -Target official
echo.
pause
