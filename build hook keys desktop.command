#!/bin/bash
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
CENTER_ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="${HOOK_KEYS_SOURCE_REPO:-$CENTER_ROOT/../apploja}"
VERSION="${1:-1.0.0}"
VERSION="${VERSION#v}"
MESSAGE="${2:-Preparar Bronze Keys Desktop $VERSION}"
WORKFLOW='hook-keys-desktop-release.yml'
REPO='JBdevy/hookupdatecenter'
finish() {
  result=$?
  if [[ $result -ne 0 ]]; then
    echo 'ERRO: o build não foi concluído. Commits e envios já realizados foram preservados; nenhum envio foi forçado.' >&2
  fi
  if [[ -t 0 && "${HOOK_BUILD_NO_PAUSE:-0}" != 1 ]]; then read -r -p 'Pressione Enter para fechar...' _ || true; fi
  exit "$result"
}
trap finish EXIT
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use X.Y.Z (padrão: 1.0.0).' >&2; exit 1; }
for tool in git gh git-lfs; do command -v "$tool" >/dev/null || { echo "Instale $tool antes de continuar." >&2; exit 1; }; done
gh auth status >/dev/null 2>&1 || { echo 'Entre no GitHub com gh auth login.' >&2; exit 1; }
cd "$CENTER_ROOT"
CENTER_BRANCH="$(git branch --show-current)"
SOURCE_BRANCH="$(git -C "$SOURCE_ROOT" branch --show-current)"
[[ -n "$CENTER_BRANCH" && -n "$SOURCE_BRANCH" ]] || { echo 'Os dois repositórios precisam estar em uma branch.' >&2; exit 1; }
# Teste a fonte que será enviada, antes de criar o disparo remoto.
(cd "$SOURCE_ROOT/Hook Keys" && node scripts/test-release.mjs)
git -C "$SOURCE_ROOT" add -- 'Hook Keys'
if ! git -C "$SOURCE_ROOT" diff --cached --quiet -- 'Hook Keys'; then
  git -C "$SOURCE_ROOT" commit --only -m "$MESSAGE" -- 'Hook Keys'
fi
git -C "$SOURCE_ROOT" push origin "$SOURCE_BRANCH"
SOURCE_REF="$(git -C "$SOURCE_ROOT" rev-parse HEAD)"
mkdir -p build
printf '%s\n' "$SOURCE_REF" > build/hook-keys-source-ref.txt
# Não incorpora arquivos de outros trabalhos já preparados no index.
FILES=('.github/workflows/hook-keys-desktop-release.yml' 'build hook keys desktop.command' 'build hook keys desktop.bat' 'build/hook-keys-source-ref.txt')
git add -- "${FILES[@]}"
git commit --allow-empty --only -m "$MESSAGE" -- "${FILES[@]}"
git push origin "$CENTER_BRANCH"
CENTER_REF="$(git rev-parse HEAD)"
# workflow_dispatch permite repetir 1.0.0 sem remover tags/releases existentes.
gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$CENTER_BRANCH" -f "version=$VERSION"
echo "Build solicitado: Bronze Keys Desktop $VERSION · fonte $SOURCE_REF"
RUN_ID=''
for attempt in $(seq 1 30); do
  RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --event workflow_dispatch --branch "$CENTER_BRANCH" --limit 10 --json databaseId,headSha --jq ".[] | select(.headSha == \"$CENTER_REF\") | .databaseId" | head -n 1)"
  [[ -z "$RUN_ID" ]] || break
  sleep 2
done
[[ -n "$RUN_ID" ]] || { echo 'O disparo foi enviado, mas a execução ainda não apareceu. Consulte o Actions.' >&2; exit 1; }
echo "https://github.com/$REPO/actions/runs/$RUN_ID"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status --interval 15
echo 'Build e publicação dos instaladores concluídos.'
