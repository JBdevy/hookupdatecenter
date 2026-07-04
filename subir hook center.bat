@echo off
chcp 65001 >nul
cls

echo ==========================================
echo   SUBIR HOOK CENTER + DISPARAR ACTIONS
echo ==========================================
echo.
echo O workflow dispara com tags:
echo   v*
echo   hook-update-*
echo.
echo Para essa versão, use: v2.9.0
echo O "C" é só visual dentro do Hook Center.
echo.

set /p COMMIT_MSG=Digite a mensagem do commit: 
if "%COMMIT_MSG%"=="" (
  echo.
  echo ERRO: mensagem do commit vazia.
  pause
  exit /b 1
)

echo.
set /p TAG_VERSION=Digite a tag da versão, exemplo v2.9.0: 
if "%TAG_VERSION%"=="" (
  echo.
  echo ERRO: tag vazia.
  pause
  exit /b 1
)

echo.
echo Commit: %COMMIT_MSG%
echo Tag: %TAG_VERSION%
echo.

for /f "delims=" %%b in ('git branch --show-current') do set BRANCH=%%b

if "%BRANCH%"=="" (
  echo ERRO: não consegui detectar a branch atual.
  pause
  exit /b 1
)

echo Branch atual: %BRANCH%
echo.

echo ==========================================
echo   ADICIONANDO ARQUIVOS
echo ==========================================
git add -A
if errorlevel 1 goto erro

echo.
echo ==========================================
echo   CRIANDO COMMIT
echo ==========================================
git commit -m "%COMMIT_MSG%"
if errorlevel 1 goto erro

echo.
echo ==========================================
echo   CRIANDO TAG
echo ==========================================
git tag -a "%TAG_VERSION%" -m "%COMMIT_MSG%"
if errorlevel 1 goto erro

echo.
echo ==========================================
echo   ENVIANDO BRANCH
echo ==========================================
git push origin "%BRANCH%"
if errorlevel 1 goto erro

echo.
echo ==========================================
echo   ENVIANDO TAG / DISPARANDO ACTIONS
echo ==========================================
git push origin "%TAG_VERSION%"
if errorlevel 1 goto erro

echo.
echo ==========================================
echo   PRONTO
echo ==========================================
echo Tag enviada: %TAG_VERSION%
echo Actions deve disparar agora pelo workflow.
echo.
pause
exit /b 0

:erro
echo.
echo ==========================================
echo   DEU ERRO
echo ==========================================
echo Verifique a mensagem acima.
echo.
pause
exit /b 1