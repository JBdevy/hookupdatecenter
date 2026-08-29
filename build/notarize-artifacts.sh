#!/usr/bin/env bash
set -euo pipefail

APPLE_ID_VALUE="${HOOK_NOTARY_APPLE_ID:-${APPLE_ID:-}}"
APPLE_PASSWORD_VALUE="${HOOK_NOTARY_PASSWORD:-${APPLE_APP_SPECIFIC_PASSWORD:-}}"
APPLE_TEAM_VALUE="${HOOK_NOTARY_TEAM_ID:-${APPLE_TEAM_ID:-}}"
# Tempo máximo por arquivo. Pode aumentar no workflow com NOTARY_TIMEOUT_MINUTES.
NOTARY_TIMEOUT_MINUTES="${NOTARY_TIMEOUT_MINUTES:-90}"
POLL_SECONDS="${NOTARY_POLL_SECONDS:-30}"

if [[ -z "$APPLE_ID_VALUE" || -z "$APPLE_PASSWORD_VALUE" || -z "$APPLE_TEAM_VALUE" ]]; then
  echo "Notarização dos artefatos bloqueada: configure APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD e APPLE_TEAM_ID nos GitHub Secrets." >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 não encontrado no runner." >&2; exit 1; }

json_get() {
  local key="$1"
  python3 -c 'import json,sys; key=sys.argv[1]; data=json.load(sys.stdin); print(data.get(key, ""))' "$key"
}

notary_submit_and_wait() {
  local file="$1"
  local max_seconds=$((NOTARY_TIMEOUT_MINUTES * 60))
  local elapsed=0
  local submit_json request_id status info_json

  echo "[macOS] Enviando para notarização Apple: $file"
  submit_json=$(xcrun notarytool submit "$file" \
    --apple-id "$APPLE_ID_VALUE" \
    --password "$APPLE_PASSWORD_VALUE" \
    --team-id "$APPLE_TEAM_VALUE" \
    --output-format json)

  echo "$submit_json"
  request_id=$(printf '%s' "$submit_json" | json_get id)

  if [[ -z "$request_id" ]]; then
    echo "Não foi possível obter o ID da submissão de notarização para: $file" >&2
    exit 1
  fi

  echo "[macOS] ID da submissão: $request_id"
  echo "[macOS] Aguardando resposta da Apple por até ${NOTARY_TIMEOUT_MINUTES} minutos..."

  while true; do
    info_json=$(xcrun notarytool info "$request_id" \
      --apple-id "$APPLE_ID_VALUE" \
      --password "$APPLE_PASSWORD_VALUE" \
      --team-id "$APPLE_TEAM_VALUE" \
      --output-format json || true)

    status=$(printf '%s' "$info_json" | json_get status 2>/dev/null || true)
    [[ -z "$status" ]] && status="Unknown"

    echo "[macOS] Status notarização: $status (${elapsed}s/${max_seconds}s)"

    case "$status" in
      Accepted)
        echo "[macOS] Notarização aprovada: $file"
        break
        ;;
      Invalid|Rejected)
        echo "[macOS] Notarização recusada: $file" >&2
        xcrun notarytool log "$request_id" \
          --apple-id "$APPLE_ID_VALUE" \
          --password "$APPLE_PASSWORD_VALUE" \
          --team-id "$APPLE_TEAM_VALUE" || true
        exit 1
        ;;
    esac

    if (( elapsed >= max_seconds )); then
      echo "[macOS] Timeout aguardando Apple. ID da submissão: $request_id" >&2
      echo "[macOS] Refaça o workflow depois. A notarização precisa voltar Accepted para entregar a cliente." >&2
      exit 1
    fi

    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
  done

  echo "[macOS] Gravando ticket no artefato: $file"
  xcrun stapler staple "$file"
  xcrun stapler validate "$file"
}

shopt -s nullglob
artifacts=(dist/*.pkg)

if [[ ${#artifacts[@]} -eq 0 ]]; then
  echo "Nenhum PKG encontrado em dist/ para notarizar." >&2
  exit 1
fi

for file in "${artifacts[@]}"; do
  notary_submit_and_wait "$file"

  echo "[macOS] Conferindo Gatekeeper do artefato: $file"
  spctl -a -vvv -t install "$file"
  echo "[macOS] Artefato pronto para cliente: $file"
done
