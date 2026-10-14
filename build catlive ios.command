#!/bin/bash
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO='JBdevy/hookupdatecenter'
WORKFLOW='catlive-ios-appstore.yml'

finish() {
  result=$?
  if [[ $result -ne 0 ]]; then
    echo 'ERRO: o envio não foi concluído. Nenhum push foi forçado.' >&2
  fi
  if [[ -t 0 && "${CATLIVE_BUILD_NO_PAUSE:-0}" != 1 ]]; then
    read -r -p 'Pressione Enter para fechar...' _ || true
  fi
}
trap finish EXIT

for tool in git gh; do
  command -v "$tool" >/dev/null || { echo "Instale $tool antes de continuar." >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo 'Entre no GitHub com gh auth login.' >&2; exit 1; }

cd "$ROOT"
BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || { echo 'Selecione uma branch antes de continuar.' >&2; exit 1; }

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  read -r -p 'Versão do CatLive [1.01]: ' VERSION
  VERSION="${VERSION:-1.01}"
fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]{2}$ ]] || { echo 'Use a versão no formato X.XX (ex.: 1.00).' >&2; exit 1; }

REQUIRED_SECRETS=(IOS_TEAM_ID IOS_CERT_P12_BASE64 IOS_CERT_PASSWORD IOS_PROVISION_PROFILE_BASE64 APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_API_KEY_P8_BASE64)
AVAILABLE_SECRETS="$(gh secret list --repo "$REPO" --json name --jq '.[].name')"
MISSING=0
for name in "${REQUIRED_SECRETS[@]}"; do
  if ! grep -Fxq "$name" <<< "$AVAILABLE_SECRETS"; then
    echo "Configure o secret antes do envio: $name" >&2
    MISSING=1
  fi
done
[[ "$MISSING" == 0 ]] || exit 1

FILES=('JarasLive' '.github/workflows/catlive-ios-appstore.yml' 'build catlive ios.command')
echo 'Alterações do CatLive que serão enviadas:'
git status --short -- "${FILES[@]}"

git add -A -- "${FILES[@]}"
git diff --cached --check -- "${FILES[@]}"
if ! git diff --cached --quiet -- "${FILES[@]}"; then
  MESSAGE="${2:-}"
  if [[ -z "$MESSAGE" ]]; then
    read -r -p 'Mensagem do commit: ' MESSAGE
  fi
  [[ -n "${MESSAGE//[[:space:]]/}" ]] || { echo 'A mensagem do commit não pode ficar vazia.' >&2; exit 1; }
  git commit --only -m "$MESSAGE" -- "${FILES[@]}"
else
  echo 'Nenhuma alteração nova do CatLive para commitar.'
fi

git push origin "$BRANCH"
HEAD_SHA="$(git rev-parse HEAD)"
BEFORE_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --event workflow_dispatch --branch "$BRANCH" --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$BRANCH" -f "version=$VERSION"

RUN_ID=''
for attempt in $(seq 1 30); do
  RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --event workflow_dispatch --branch "$BRANCH" --limit 20 --json databaseId,headSha --jq ".[] | select(.headSha == \"$HEAD_SHA\" and .databaseId > $BEFORE_ID) | .databaseId" | head -n 1)"
  [[ -n "$RUN_ID" ]] && break
  sleep 2
done

if [[ -n "$RUN_ID" ]]; then
  echo "Build iOS do CatLive $VERSION disparado: https://github.com/$REPO/actions/runs/$RUN_ID"
else
  echo "Build iOS do CatLive $VERSION disparado. Consulte https://github.com/$REPO/actions/workflows/$WORKFLOW"
fi
echo "O IPA será enviado para processamento no App Store Connect, com novo número de build e mantendo a versão $VERSION."
