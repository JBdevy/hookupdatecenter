@echo off
setlocal
set "HOOK_ELECTRON=%~dp0..\..\Hook center\node_modules\.bin\electron.cmd"
if not exist "%HOOK_ELECTRON%" (
  echo Electron da Hook Center nao foi encontrado.
  pause
  exit /b 1
)
call "%HOOK_ELECTRON%" "%~dp0"
