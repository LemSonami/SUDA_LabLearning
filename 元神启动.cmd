@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ensure-tampermonkey.ps1"
set "helper_exit=%errorlevel%"
echo.
pause
exit /b %helper_exit%