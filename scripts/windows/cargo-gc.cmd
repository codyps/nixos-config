@echo off
setlocal

where pwsh.exe >nul 2>nul
if errorlevel 1 goto windows_powershell

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cargo-gc.ps1" %*
exit /b %errorlevel%

:windows_powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cargo-gc.ps1" %*
exit /b %errorlevel%
