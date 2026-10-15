#!/bin/bash
set -euo pipefail
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO='JBdevy/vshookapploja'
WORKFLOW='catlive-app-release.yml'
TEMP_RELEASE=''
finish() {
  result=$?
  if [[ -n "$TEMP_RELEASE" && -d "$TEMP_RELEASE" ]]; then rm -rf -- "$TEMP_RELEASE"; fi
  if [[ $result -ne 0 ]]; then echo 'ERRO: envio incompleto. Confira a última operação acima antes de tentar novamente; nenhum push foi forçado.' >&2; fi
  if [[ -t 0 && "${CATLIVE_BUILD_NO_PAUSE:-0}" != 1 ]]; then read -r -p 'Pressione Enter para fechar...' _ || true; fi
}
trap finish EXIT
for tool in git gh python3; do command -v "$tool" >/dev/null || { echo "Instale $tool antes de continuar." >&2; exit 1; }; done
cd "$ROOT"
BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || { echo 'Selecione uma branch antes de continuar.' >&2; exit 1; }
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then read -r -p 'Versão do CatLive [1.01]: ' VERSION; VERSION="${VERSION:-1.01}"; fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]{2}$ ]] || { echo 'Use X.XX (ex.: 1.01).' >&2; exit 1; }
MESSAGE="${2:-}"
if [[ -z "$MESSAGE" ]]; then read -r -p 'Mensagem do commit: ' MESSAGE; fi
[[ -n "${MESSAGE//[[:space:]]/}" ]] || { echo 'Informe a mensagem do commit.' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Entre no GitHub com gh auth login.' >&2; exit 1; }
AVAILABLE_SECRETS="$(gh secret list --repo "$REPO" --json name --jq '.[].name')"
for name in IOS_TEAM_ID IOS_CERT_P12_BASE64 IOS_CERT_PASSWORD CATLIVE_IOS_PROVISION_PROFILE_BASE64 CATLIVE_APP_STORE_CONNECT_KEY_ID CATLIVE_APP_STORE_CONNECT_ISSUER_ID CATLIVE_APP_STORE_CONNECT_API_KEY_P8_BASE64; do
  grep -Fxq "$name" <<< "$AVAILABLE_SECRETS" || { echo "Secret ausente em $REPO: $name" >&2; exit 1; }
done
# An isolated checkout preserves every uncommitted VS Hook change in Documents/apploja.
TEMP_RELEASE="$(mktemp -d "${TMPDIR:-/tmp}/catlive-app-release.XXXXXX")"
gh repo clone "$REPO" "$TEMP_RELEASE/repo" -- --depth 1 --no-tags
RELEASE_BRANCH="$(git -C "$TEMP_RELEASE/repo" branch --show-current)"
[[ -n "$RELEASE_BRANCH" ]] || exit 1
git -C "$TEMP_RELEASE/repo" config user.name "$(git config user.name)"
git -C "$TEMP_RELEASE/repo" config user.email "$(git config user.email)"
git -C "$TEMP_RELEASE/repo" ls-remote --tags --refs origin 'catlive-app-v*-build*' > "$TEMP_RELEASE/tags"
BUILD_NUMBER="$(python3 - "$TEMP_RELEASE/tags" "${CATLIVE_MIN_BUILD_NUMBER:-1001}" <<'PY'
import re, sys
assert re.fullmatch(r'[1-9][0-9]*', sys.argv[2]), 'Build mínimo deve ser um inteiro positivo'
numbers = [int(m.group(1)) for m in re.finditer(r'refs/tags/catlive-app-v[0-9]+\.[0-9]{2}-build([1-9][0-9]*)', open(sys.argv[1]).read())]
print(max(max([1000] + numbers) + 1, int(sys.argv[2])))
PY
)"
TAG="catlive-app-v$VERSION-build$BUILD_NUMBER"
FILES=('JarasLive' '.github/workflows/catlive-ios-appstore.yml' 'build catlive app.command' 'build catlive ios.command' 'scripts/catlive-app-release.yml' 'scripts/test-catlive-app-release.py')
echo "CatLive App $VERSION — build $BUILD_NUMBER"
git status --short -- "${FILES[@]}"
git add -A -- "${FILES[@]}"
git diff --cached --check -- "${FILES[@]}"
if ! git diff --cached --quiet -- "${FILES[@]}"; then git commit --only -m "$MESSAGE" -- "${FILES[@]}"; fi
SOURCE_SHA="$(git rev-parse HEAD)"
# Publish the exact source before installing the workflow pinned to this SHA.
git push origin "$BRANCH"
python3 - "$ROOT/scripts/catlive-app-release.yml" "$TEMP_RELEASE/repo" "$SOURCE_SHA" "$VERSION" "$BUILD_NUMBER" <<'PY'
import json, pathlib, re, sys
template, checkout, source, version, build = sys.argv[1:]
assert re.fullmatch(r'[0-9a-f]{40}', source)
folder = pathlib.Path(checkout) / '.github'; (folder / 'workflows').mkdir(parents=True, exist_ok=True)
(folder / 'workflows/catlive-app-release.yml').write_text(pathlib.Path(template).read_text().replace('__CATLIVE_SOURCE_SHA__', source))
(folder / 'catlive-app-release.json').write_text(json.dumps(dict(version=version, build_number=build, source_ref=source), indent=2) + '\n')
PY
git -C "$TEMP_RELEASE/repo" add -- .github/workflows/catlive-app-release.yml .github/catlive-app-release.json
git -C "$TEMP_RELEASE/repo" diff --cached --check
git -C "$TEMP_RELEASE/repo" commit -m "$MESSAGE" -- .github/workflows/catlive-app-release.yml .github/catlive-app-release.json
git -C "$TEMP_RELEASE/repo" tag -a "$TAG" -m "CatLive App $VERSION build $BUILD_NUMBER; source $SOURCE_SHA"
# Atomically publish branch and tag. A concurrent push is rejected, never overwritten.
git -C "$TEMP_RELEASE/repo" push --atomic origin "HEAD:refs/heads/$RELEASE_BRANCH" "refs/tags/$TAG"
echo "Build disparado pela tag $TAG"
echo "Acompanhar: https://github.com/$REPO/actions/workflows/$WORKFLOW"
echo "IPA: https://github.com/$REPO/releases/tag/$TAG"
echo 'O workflow assina o IPA, envia ao App Store Connect e publica somente CatLive.ipa na Release.'
echo 'A disponibilidade no TestFlight depende do processamento da Apple.'
