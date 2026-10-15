@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0JarasLive\Windows\build.ps1" -Run
if errorlevel 1 pause
