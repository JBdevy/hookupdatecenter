#!/bin/bash
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
finish() {
  result=$?
  if [[ $result -ne 0 ]]; then
    echo 'ERRO: build não concluído. Commits e tags foram preservados, sem envio forçado.' >&2
  fi
  if [[ -t 0 && "${HOOK_BUILD_NO_PAUSE:-0}" != 1 ]]; then read -r -p 'Enter para fechar...' _ || true; fi
  exit "$result"
}
trap finish EXIT
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"
MESSAGE="${2:-Build Hook Center $VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use X.Y.Z.'; exit 1; }
for tool in git npm gh; do command -v "$tool" >/dev/null; done
gh auth status >/dev/null 2>&1
BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]]
npm run test:relay-performance
npm run test:apple-peer
npm run test:license-offline
npm version "$VERSION" --no-git-tag-version --allow-same-version
# Commit somente dos arquivos de versão e do lançador; outros trabalhos ficam preservados.
git add package.json package-lock.json 'build hook center.command'
if ! git diff --cached --quiet -- package.json package-lock.json 'build hook center.command'; then
  git commit --only -m "$MESSAGE" -- package.json package-lock.json 'build hook center.command'
fi
# Tags de build independentes permitem manter 1.0.0 sem reescrever releases.
TAG="hook-update-$VERSION-build$(date -u +%Y%m%d%H%M%S)"
git tag -a "$TAG" -m "$MESSAGE"
git push origin "$BRANCH"
git push origin "$TAG"
RUN=''
for attempt in $(seq 1 30); do
  RUN="$(gh run list --repo JBdevy/hookupdatecenter --workflow build-release.yml --branch "$TAG" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [[ -z "$RUN" ]] || break
  sleep 2
done
[[ -n "$RUN" ]] || { echo "Consulte Actions para $TAG"; exit 1; }
echo "https://github.com/JBdevy/hookupdatecenter/actions/runs/$RUN"
gh run watch "$RUN" --repo JBdevy/hookupdatecenter --exit-status --interval 15
echo 'Instaladores compilados e publicados.'
