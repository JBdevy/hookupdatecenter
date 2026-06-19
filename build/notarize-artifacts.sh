#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${APPLE_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" || -z "${APPLE_TEAM_ID:-}" ]]; then
  echo "Notarização dos artefatos bloqueada: configure APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD e APPLE_TEAM_ID nos GitHub Secrets." >&2
  exit 1
fi

shopt -s nullglob
artifacts=(dist/*.dmg dist/*.pkg)

if [[ ${#artifacts[@]} -eq 0 ]]; then
  echo "Nenhum DMG/PKG encontrado em dist/ para notarizar." >&2
  exit 1
fi

for file in "${artifacts[@]}"; do
  echo "[macOS] Notarizando artefato final: $file"
  xcrun notarytool submit "$file" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

  echo "[macOS] Gravando ticket no artefato: $file"
  xcrun stapler staple "$file"

  echo "[macOS] Conferindo Gatekeeper do artefato: $file"
  spctl -a -vvv -t open --context context:primary-signature "$file" || true

done
