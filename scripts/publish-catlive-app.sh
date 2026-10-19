#!/bin/bash
set -euo pipefail
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO='JBdevy/vshookapploja'
finish() {
  result=$?
  if [[ $result -ne 0 ]]; then echo 'ERRO: envio incompleto. Nenhum push foi forçado.' >&2; fi
  if [[ -t 0 && "${CATLIVE_BUILD_NO_PAUSE:-0}" != 1 ]]; then read -r -p 'Pressione Enter para fechar...' _ || true; fi
}
trap finish EXIT
for tool in git gh python3; do command -v "$tool" >/dev/null || { echo "Instale $tool antes de continuar." >&2; exit 1; }; done
cd "$ROOT"
ORIGIN="$(git config --get remote.origin.url)"
case "$ORIGIN" in
  https://github.com/JBdevy/vshookapploja|https://github.com/JBdevy/vshookapploja.git|git@github.com:JBdevy/vshookapploja.git) ;;
  *) echo 'Execute este publicador no repositório vshookapploja.' >&2; exit 1 ;;
esac
BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || { echo 'Selecione uma branch antes de continuar.' >&2; exit 1; }
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then read -r -p 'Versão do CatLive [1.04]: ' VERSION; VERSION="${VERSION:-1.04}"; fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]{2}$ ]] || { echo 'Use X.XX (ex.: 1.04).' >&2; exit 1; }
MESSAGE="${2:-}"
if [[ -z "$MESSAGE" ]]; then read -r -p 'Mensagem do commit: ' MESSAGE; fi
[[ -n "${MESSAGE//[[:space:]]/}" ]] || { echo 'Informe a mensagem do commit.' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Entre no GitHub com gh auth login.' >&2; exit 1; }
AVAILABLE_SECRETS="$(gh secret list --repo "$REPO" --json name --jq '.[].name')"
for name in IOS_TEAM_ID IOS_CERT_P12_BASE64 IOS_CERT_PASSWORD CATLIVE_IOS_PROVISION_PROFILE_BASE64 CATLIVE_APP_STORE_CONNECT_KEY_ID CATLIVE_APP_STORE_CONNECT_ISSUER_ID CATLIVE_APP_STORE_CONNECT_API_KEY_P8_BASE64; do
  grep -Fxq "$name" <<< "$AVAILABLE_SECRETS" || { echo "Secret ausente em $REPO: $name" >&2; exit 1; }
done
BUILD_NUMBER="$(git ls-remote --tags --refs origin 'catlive-app-v*-build*' | python3 -c '
import re, sys
minimum = sys.argv[1]
assert re.fullmatch(r"[1-9][0-9]*", minimum), "Build mínimo deve ser um inteiro positivo"
numbers = [int(m.group(1)) for m in re.finditer(r"refs/tags/catlive-app-v[0-9]+\.[0-9]{2}-build([1-9][0-9]*)", sys.stdin.read())]
print(max(max([1000] + numbers) + 1, int(minimum)))
' "${CATLIVE_MIN_BUILD_NUMBER:-1001}")"
TAG="catlive-app-v$VERSION-build$BUILD_NUMBER"
FILES=('JarasLive' '.github/workflows/catlive-ios-appstore.yml' '.github/workflows/catlive-app-release.yml' 'build catlive app.command' 'build catlive ios.command' 'scripts/publish-catlive-app.sh' 'scripts/test-catlive-app-release.py')
echo "CatLive App $VERSION — build $BUILD_NUMBER — código em $REPO"
git status --short -- "${FILES[@]}"
git add -A -- "${FILES[@]}"
git diff --cached --check -- "${FILES[@]}"
if ! git diff --cached --quiet -- "${FILES[@]}"; then git commit --only -m "$MESSAGE" -- "${FILES[@]}"; fi
SOURCE_SHA="$(git rev-parse HEAD)"
python3 - "$VERSION" "$BUILD_NUMBER" "$SOURCE_SHA" <<'PY'
import json, pathlib, sys
version, build, source = sys.argv[1:]
folder = pathlib.Path('.github'); folder.mkdir(exist_ok=True)
(folder / 'catlive-app-release.json').write_text(json.dumps(dict(version=version, build_number=build, source_ref=source), indent=2) + '\n')
PY
git add -- .github/catlive-app-release.json
git diff --cached --check -- .github/catlive-app-release.json
git commit --only -m "Release CatLive App $VERSION build $BUILD_NUMBER" -- .github/catlive-app-release.json
git tag -a "$TAG" -m "CatLive App $VERSION build $BUILD_NUMBER; source $SOURCE_SHA"
git push --atomic origin "HEAD:refs/heads/$BRANCH" "refs/tags/$TAG"
echo "Build disparado: $TAG"
echo "Acompanhar: https://github.com/$REPO/actions/workflows/catlive-app-release.yml"
echo "IPA: https://github.com/$REPO/releases/tag/$TAG"
echo 'Código e build pertencem ao repositório do app. IPA enviado ao App Store Connect pelo workflow.'
