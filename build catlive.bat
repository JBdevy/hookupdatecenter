@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
echo CatLive - release macOS + Windows 10/11 x64
echo.
echo Compila as duas plataformas no GitHub Actions e publica os instaladores
echo juntos depois dos testes de compatibilidade dos projetos .jl.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\publish-catlive-desktop.ps1" %*
set "CATLIVE_RESULT=%ERRORLEVEL%"
echo.
if not "%CATLIVE_RESULT%"=="0" echo O processo foi interrompido. Confira o erro acima.
pause
exit /b %CATLIVE_RESULT%
