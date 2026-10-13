@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install-windows.ps1" -SourceDirectory "%~dp0." -Launch
if errorlevel 1 pause
