@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"

where git >nul 2>&1 || (
  echo Git nao encontrado neste computador.
  pause
  exit /b 1
)

git rev-parse --is-inside-work-tree >nul 2>&1 || (
  echo Esta pasta nao e um repositorio Git valido.
  pause
  exit /b 1
)

for /f "delims=" %%B in ('git branch --show-current') do set "BRANCH=%%B"
if not defined BRANCH (
  echo Nao foi possivel detectar a branch atual.
  pause
  exit /b 1
)

:pedir_versao
set "HOOK_KEYS_VERSION="
set /p "HOOK_KEYS_VERSION=Versao do Hook Keys (exemplo 1.0.0): "
if not defined HOOK_KEYS_VERSION goto pedir_versao
if /i "%HOOK_KEYS_VERSION:~0,1%"=="v" set "HOOK_KEYS_VERSION=%HOOK_KEYS_VERSION:~1%"
echo(%HOOK_KEYS_VERSION%| findstr /r /x "[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" >nul
if errorlevel 1 (
  echo Use uma versao como 1.0.0.
  goto pedir_versao
)

set "HOOK_KEYS_TAG=hook-keys-desktop-v%HOOK_KEYS_VERSION%"
set "TAG_LOCAL=0"
set "TAG_REMOTE=0"
git show-ref --verify --quiet "refs/tags/%HOOK_KEYS_TAG%"
if not errorlevel 1 set "TAG_LOCAL=1"
git ls-remote --exit-code --tags origin "refs/tags/%HOOK_KEYS_TAG%" >nul 2>&1
if not errorlevel 1 set "TAG_REMOTE=1"

if "%TAG_LOCAL%"=="0" if "%TAG_REMOTE%"=="0" goto preparar_envio
echo.
echo A tag %HOOK_KEYS_TAG% ja existe, mas pode ser recriada para repetir o build.
choice /c SN /n /m "Excluir e recriar essa tag? [S/N]: "
if errorlevel 2 exit /b 0
if "%TAG_LOCAL%"=="1" git tag -d "%HOOK_KEYS_TAG%" || goto erro
if "%TAG_REMOTE%"=="1" git push origin --delete "%HOOK_KEYS_TAG%" || goto erro

:preparar_envio
set "COMMIT_MSG=Preparar Hook Keys Desktop %HOOK_KEYS_VERSION%"
set "CUSTOM_MSG="
set /p "CUSTOM_MSG=Mensagem do commit [%COMMIT_MSG%]: "
if defined CUSTOM_MSG set "COMMIT_MSG=%CUSTOM_MSG%"

rem O workflow desktop mora neste repositorio, mas compila o codigo mantido no
rem repositorio vshookapploja. Envia primeiro a fonte local para impedir que a
rem Action baixe e compile uma revisao antiga do Hook Keys.
set "HOOK_KEYS_SOURCE_REPO=%~dp0..\apploja"
git -C "%HOOK_KEYS_SOURCE_REPO%" rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 goto erro_fonte_ausente

set "HOOK_KEYS_SOURCE_BRANCH="
for /f "delims=" %%B in ('git -C "%HOOK_KEYS_SOURCE_REPO%" branch --show-current') do set "HOOK_KEYS_SOURCE_BRANCH=%%B"
if not defined HOOK_KEYS_SOURCE_BRANCH goto erro_fonte_branch

echo Enviando o codigo atualizado do Hook Keys para %HOOK_KEYS_SOURCE_BRANCH%...
git -C "%HOOK_KEYS_SOURCE_REPO%" add -- "Hook Keys"
if errorlevel 1 goto erro_fonte
git -C "%HOOK_KEYS_SOURCE_REPO%" diff --cached --quiet
if errorlevel 1 git -C "%HOOK_KEYS_SOURCE_REPO%" commit -m "%COMMIT_MSG%"
if errorlevel 1 goto erro_fonte
git -C "%HOOK_KEYS_SOURCE_REPO%" push origin "%HOOK_KEYS_SOURCE_BRANCH%"
if errorlevel 1 goto erro_fonte

for /f "delims=" %%S in ('git -C "%HOOK_KEYS_SOURCE_REPO%" rev-parse HEAD') do set "HOOK_KEYS_SOURCE_REF=%%S"
if not defined HOOK_KEYS_SOURCE_REF goto erro_fonte
if not exist build mkdir build
> "build\hook-keys-source-ref.txt" echo %HOOK_KEYS_SOURCE_REF%

git add -- ".github/workflows/hook-keys-desktop-release.yml" "build hook keys desktop.bat" "build hook keys desktop.command" "build/hook-keys-source-ref.txt"
if errorlevel 1 goto erro
rem Sempre cria um commit proprio para este disparo. Sem --allow-empty, quando
rem nao havia mudanca no workflow o nome digitado era ignorado e a tag ficava
rem apontando para o ultimo commit da Hook Center (por exemplo, Hook Center 1.0.2).
git commit --allow-empty -m "%COMMIT_MSG%" || goto erro

echo Enviando o workflow para a branch %BRANCH%...
git push origin "%BRANCH%" || goto erro

git tag -a "%HOOK_KEYS_TAG%" -m "Hook Keys Desktop %HOOK_KEYS_VERSION%" || goto erro
echo Disparando o GitHub Actions...
git push origin "%HOOK_KEYS_TAG%" || goto erro_tag

echo.
echo Build desktop do Hook Keys disparado pela tag %HOOK_KEYS_TAG%.
echo Acompanhe em: https://github.com/JBdevy/hookupdatecenter/actions
pause
exit /b 0

:erro_tag
git tag -d "%HOOK_KEYS_TAG%" >nul 2>&1
goto erro

:erro_fonte_ausente
echo.
echo A pasta do repositorio do app nao foi encontrada em:
echo %HOOK_KEYS_SOURCE_REPO%
goto erro

:erro_fonte_branch
echo.
echo Nao foi possivel detectar a branch do repositorio do Hook Keys.
goto erro

:erro_fonte
echo.
echo Falha ao enviar o codigo do Hook Keys para o repositorio do app.
goto erro

:erro
echo.
echo Falha ao preparar ou enviar o build do Hook Keys Desktop.
pause
exit /b 1
