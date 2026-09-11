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

git add -- ".github/workflows/hook-keys-desktop-release.yml" "build hook keys desktop.bat"
if errorlevel 1 goto erro
git diff --cached --quiet
if errorlevel 1 git commit -m "%COMMIT_MSG%" || goto erro

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

:erro
echo.
echo Falha ao preparar ou enviar o build do Hook Keys Desktop.
pause
exit /b 1
