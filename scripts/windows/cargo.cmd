@echo off
setlocal

where pwsh.exe >nul 2>nul
if errorlevel 1 goto windows_powershell

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cargo-with-cached-target.ps1" %*
exit /b %errorlevel%

:windows_powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cargo-with-cached-target.ps1" %*
exit /b %errorlevel%
