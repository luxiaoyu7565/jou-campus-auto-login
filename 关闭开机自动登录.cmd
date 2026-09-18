@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0CampusHelper.ps1" -Uninstall
if errorlevel 1 pause
