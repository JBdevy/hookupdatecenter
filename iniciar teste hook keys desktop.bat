@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title Hook Keys Desktop - Teste local

set "HOOK_KEYS_LOCAL=%~dp0..\apploja\Hook Keys"
if not exist "%HOOK_KEYS_LOCAL%\iniciar teste desktop.bat" goto fonte_ausente

echo Abrindo a fonte desktop compartilhada em:
echo %HOOK_KEYS_LOCAL%
echo.
call "%HOOK_KEYS_LOCAL%\iniciar teste desktop.bat"
exit /b %errorlevel%

:fonte_ausente
echo ERRO: o codigo compartilhado do Hook Keys nao foi encontrado em:
echo %HOOK_KEYS_LOCAL%
pause
exit /b 1
