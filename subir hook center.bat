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
set "TAG_EXISTS_LOCAL=0"
set "TAG_EXISTS_REMOTE=0"

git show-ref --verify --quiet "refs/tags/%TAG_VERSION%"
if not errorlevel 1 set "TAG_EXISTS_LOCAL=1"

git ls-remote --exit-code --tags origin "refs/tags/%TAG_VERSION%" >nul 2>&1
set "REMOTE_TAG_CHECK=%errorlevel%"
if "%REMOTE_TAG_CHECK%"=="0" set "TAG_EXISTS_REMOTE=1"
if "%REMOTE_TAG_CHECK%"=="2" goto tag_check_concluido
if not "%REMOTE_TAG_CHECK%"=="0" goto erro_consulta_tag

:tag_check_concluido
if "%TAG_EXISTS_LOCAL%"=="1" goto tag_existente
if "%TAG_EXISTS_REMOTE%"=="1" goto tag_existente

:versao_confirmada
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
if errorlevel 1 goto fallback_api

echo.
echo ==========================================
echo   ENVIANDO TAG / DISPARANDO ACTIONS
echo ==========================================
git push origin "%TAG_VERSION%"
if errorlevel 1 goto fallback_api

goto pronto

:fallback_api
echo.
echo O endpoint Git do GitHub recusou o push.
echo Tentando a API oficial, sem build local...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\push-github-api.ps1" -Branch "%BRANCH%" -Tag "%TAG_VERSION%"
if errorlevel 1 goto erro

:pronto

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
echo ATENCAO: a tag %TAG_VERSION% ja existe.
if "%TAG_EXISTS_LOCAL%"=="1" echo Ela existe localmente.
if "%TAG_EXISTS_REMOTE%"=="1" echo Ela existe no GitHub.
echo.
choice /c SN /n /m "Deseja excluir essa tag para recria-la? [S/N]: "
if errorlevel 2 goto pedir_versao

if "%TAG_EXISTS_LOCAL%"=="1" goto excluir_tag_local
goto verificar_exclusao_tag_remota

:excluir_tag_local
git tag -d "%TAG_VERSION%"
if errorlevel 1 goto erro

:verificar_exclusao_tag_remota
if "%TAG_EXISTS_REMOTE%"=="1" goto excluir_tag_remota
goto tag_excluida

:excluir_tag_remota
echo.
echo Excluindo %TAG_VERSION% do GitHub...
git push origin --delete "%TAG_VERSION%"
if errorlevel 1 goto erro

:tag_excluida
echo.
echo Tag %TAG_VERSION% excluida. Ela sera criada novamente no novo commit.
echo.
goto versao_confirmada

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

:erro_consulta_tag
echo ERRO: nao foi possivel consultar as tags no GitHub.
echo Verifique a internet e o acesso ao repositorio origin.
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
