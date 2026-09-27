#!/bin/bash
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
finish() {
  result=$?
  if [[ $result -ne 0 ]]; then
    echo 'ERRO: envio não concluído. Confira a mensagem acima; nenhum envio foi forçado.' >&2
  fi
  if [[ -t 0 && "${HOOK_BUILD_NO_PAUSE:-0}" != 1 ]]; then read -r -p 'Enter para fechar...' _ || true; fi
  exit "$result"
}
trap finish EXIT
cd "$(dirname "$0")"
for tool in git npm node; do
  command -v "$tool" >/dev/null || { echo "ERRO: $tool não encontrado."; exit 1; }
done
git rev-parse --is-inside-work-tree >/dev/null
BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || { echo 'ERRO: selecione uma branch antes de continuar.'; exit 1; }
DEFAULT_VERSION="$(node -p 'require("./package.json").version')"
echo 'SUBIR HOOK CENTER + DISPARAR ACTIONS'
echo 'Atualiza a versão, adiciona as alterações, cria o commit e envia a branch e a tag vX.Y.Z.'
VERSION="${1:-}"
while true; do
  if [[ -z "$VERSION" ]]; then
    read -r -p "Digite a versão da Hook Center [$DEFAULT_VERSION]: " VERSION
    VERSION="${VERSION:-$DEFAULT_VERSION}"
  fi
  VERSION="${VERSION#v}"; VERSION="${VERSION#V}"
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'ERRO: use X.Y.Z, por exemplo 1.0.2.'
    VERSION=''; continue
  fi
  TAG="v$VERSION"
  LOCAL_TAG=0; REMOTE_TAG=0; RECREATE=0
  if git show-ref --verify --quiet "refs/tags/$TAG"; then LOCAL_TAG=1; fi
  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null; then
    REMOTE_TAG=1
  else
    status=$?
    [[ $status -eq 2 ]] || { echo 'ERRO: não foi possível consultar as tags no GitHub.'; exit 1; }
  fi
  if [[ $LOCAL_TAG -eq 1 || $REMOTE_TAG -eq 1 ]]; then
    echo "ATENÇÃO: a tag $TAG já existe."
    read -r -p 'Deseja excluir essa tag para recriá-la? [S/N]: ' answer
    case "$answer" in s|S) RECREATE=1 ;; *) VERSION=''; continue ;; esac
  fi
  break
done
MESSAGE="${2:-}"
if [[ -z "$MESSAGE" ]]; then read -r -p 'Digite a mensagem do commit: ' MESSAGE; fi
[[ -n "${MESSAGE//[[:space:]]/}" ]] || { echo 'ERRO: mensagem do commit vazia.'; exit 1; }
printf '\nBranch: %s\nVersão dos instaladores: %s\nTag: %s\nCommit: %s\n' "$BRANCH" "$VERSION" "$TAG" "$MESSAGE"
echo 'Alterações que serão incluídas (assim como git add -A no .bat):'
git status --short
read -r -p 'Continuar? [S/N]: ' answer
case "$answer" in s|S) ;; *) echo 'Cancelado. Nenhum arquivo, commit ou tag foi alterado.'; exit 0 ;; esac
npm version "$VERSION" --no-git-tag-version --allow-same-version
# Exclusão somente após as confirmações acima; nunca sobrescreve tags silenciosamente.
if [[ $RECREATE -eq 1 ]]; then
  if [[ $REMOTE_TAG -eq 1 ]]; then git push origin --delete "$TAG"; fi
  if [[ $LOCAL_TAG -eq 1 ]]; then git tag -d "$TAG"; fi
fi
git add -A
if ! git diff --cached --quiet; then git commit -m "$MESSAGE"; fi
git tag -a "$TAG" -m "$MESSAGE"
if git push origin "$BRANCH" && git push origin "$TAG"; then
  :
else
  if command -v pwsh >/dev/null && [[ -f scripts/push-github-api.ps1 ]]; then
    echo 'Tentando o fallback da API oficial, como no .bat...'
    pwsh -NoProfile -File scripts/push-github-api.ps1 -Branch "$BRANCH" -Tag "$TAG"
  else
    echo 'ERRO: push falhou. Commits e tags foram preservados. O fallback do .bat requer PowerShell (pwsh).'
    exit 1
  fi
fi
printf '\nHook Center: %s\nTag enviada: %s\nO GitHub Actions deve iniciar agora.\n' "$VERSION" "$TAG"
