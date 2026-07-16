@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul

cd /d "%~dp0"
if errorlevel 1 goto erro_pasta

cls
echo ==========================================
echo   SUBIR HOOK CENTER + DISPARAR ACTIONS
echo ==========================================
echo.
echo Este processo:
echo   1. Atualiza a versao do package.json e package-lock.json.
echo   2. Cria o commit.
echo   3. Cria a tag vX.Y.Z.
echo   4. Envia a branch e a tag para o GitHub Actions.
echo.

where git >nul 2>&1
if errorlevel 1 goto erro_git

where npm >nul 2>&1
if errorlevel 1 goto erro_npm

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 goto erro_repositorio

for /f "delims=" %%b in ('git branch --show-current') do set "BRANCH=%%b"
if not defined BRANCH goto erro_branch

:pedir_versao
set "VERSION="
set /p "VERSION=Digite a versao da Hook Center, exemplo 3.0.0: "
if not defined VERSION goto versao_vazia

if /i "%VERSION:~0,1%"=="v" set "VERSION=%VERSION:~1%"

echo(%VERSION%| findstr /r /x "[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" >nul
if errorlevel 1 goto versao_invalida

set "TAG_VERSION=v%VERSION%"

git fetch --tags origin
if errorlevel 1 goto erro

git rev-parse -q --verify "refs/tags/%TAG_VERSION%" >nul 2>&1
if not errorlevel 1 goto tag_existente

set "COMMIT_MSG="
set /p "COMMIT_MSG=Digite a mensagem do commit: "
if not defined COMMIT_MSG goto commit_vazio

echo.
echo Branch: %BRANCH%
echo Versao dos instaladores: %VERSION%
echo Tag que sera criada: %TAG_VERSION%
echo Commit: %COMMIT_MSG%
echo.
choice /c SN /n /m "Continuar? [S/N]: "
if errorlevel 2 goto cancelado

echo.
echo ==========================================
echo   ATUALIZANDO VERSAO DO PACOTE
echo ==========================================
call npm version "%VERSION%" --no-git-tag-version --allow-same-version
if errorlevel 1 goto erro

echo.
echo ==========================================
echo   ADICIONANDO ARQUIVOS
echo ==========================================
git add -A
if errorlevel 1 goto erro

git diff --cached --quiet
if errorlevel 1 goto criar_commit

echo.
echo Nenhuma alteracao nova para criar commit.
echo A tag sera criada no commit atual.
goto criar_tag

:criar_commit
echo.
echo ==========================================
echo   CRIANDO COMMIT
echo ==========================================
git commit -m "%COMMIT_MSG%"
if errorlevel 1 goto erro

:criar_tag
echo.
echo ==========================================
echo   CRIANDO TAG %TAG_VERSION%
echo ==========================================
git tag -a "%TAG_VERSION%" -m "%COMMIT_MSG%"
if errorlevel 1 goto erro

echo.
echo ==========================================
echo   ENVIANDO BRANCH %BRANCH%
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
echo Hook Center: %VERSION%
echo Tag enviada: %TAG_VERSION%
echo O GitHub Actions deve iniciar agora.
echo.
pause
exit /b 0

:versao_vazia
echo.
echo ERRO: digite uma versao.
echo.
goto pedir_versao

:versao_invalida
echo.
echo ERRO: use o formato X.Y.Z, por exemplo 3.0.0.
echo Nao digite letras nem sufixos. O prefixo v e colocado automaticamente.
echo.
goto pedir_versao

:tag_existente
echo.
echo ERRO: a tag %TAG_VERSION% ja existe.
echo Digite uma versao nova.
echo.
goto pedir_versao

:commit_vazio
echo.
echo ERRO: mensagem do commit vazia.
echo.
pause
exit /b 1

:cancelado
echo.
echo Operacao cancelada. Nenhum arquivo, commit ou tag foi alterado.
echo.
pause
exit /b 0

:erro_pasta
echo ERRO: nao foi possivel abrir a pasta da Hook Center.
pause
exit /b 1

:erro_git
echo ERRO: Git nao foi encontrado no PATH.
pause
exit /b 1

:erro_npm
echo ERRO: npm nao foi encontrado no PATH.
pause
exit /b 1

:erro_repositorio
echo ERRO: esta pasta nao e um repositorio Git valido.
pause
exit /b 1

:erro_branch
echo ERRO: nao consegui detectar a branch atual.
pause
exit /b 1

:erro
echo.
echo ==========================================
echo   DEU ERRO
echo ==========================================
echo Verifique a mensagem acima. Nenhum novo push sera tentado.
echo.
pause
exit /b 1
