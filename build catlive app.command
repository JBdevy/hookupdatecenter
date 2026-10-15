#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${CATLIVE_APP_REPO_DIR:-}" ]]; then
  APP_ROOT="$CATLIVE_APP_REPO_DIR"
elif [[ "$(git -C "$ROOT" config --get remote.origin.url)" == *JBdevy/vshookapploja* ]]; then
  APP_ROOT="$ROOT"
else
  APP_ROOT="$ROOT/../apploja"
fi
[[ -f "$APP_ROOT/scripts/publish-catlive-app.sh" ]] || {
  echo 'Publicador não encontrado na pasta apploja. Configure CATLIVE_APP_REPO_DIR com o repositório do app.' >&2
  exit 1
}
exec bash "$APP_ROOT/scripts/publish-catlive-app.sh" "$@"
