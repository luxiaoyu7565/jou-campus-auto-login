@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0CampusHelper.ps1" -Setup
if errorlevel 1 (
  echo Startup failed. Please keep this window open.
  pause
)
