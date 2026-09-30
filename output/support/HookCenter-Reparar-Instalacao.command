#!/bin/bash
set -euo pipefail
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Este reparo e somente para macOS." >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "O macOS pedira a senha de administrador para reparar o caminho global do REAPER."
  exec sudo /bin/bash "$0"
fi
#!/bin/bash
# Shared by the PKG and in-app installer. Keep valid directory symlinks intact.
# Invalid directory symlinks are moved aside, never followed or deleted.
hook_ensure_directory() {
  local directory="$1" backup suffix=0
  [ -d "$directory" ] && return 0
  if [ -L "$directory" ]; then
    backup="${directory}.hook-link-backup.$(date +%Y%m%d-%H%M%S).$$"
    while [ -e "$backup" ] || [ -L "$backup" ]; do
      suffix=$((suffix + 1))
      backup="${directory}.hook-link-backup.$(date +%Y%m%d-%H%M%S).$$.$suffix"
    done
    mv "$directory" "$backup" || return 1
    echo "[Hook Center] Link de diretorio invalido preservado em: $backup"
  elif [ -e "$directory" ]; then
    echo "[Hook Center] ERRO: existe um arquivo no lugar do diretorio: $directory" >&2
    return 1
  fi
  mkdir -p "$directory"
}

hook_prepare_reaper_directories() {
  local root="$1" child
  hook_ensure_directory "$root" || return 1
  for child in UserPlugins ColorThemes Scripts; do
    hook_ensure_directory "$root/$child" || return 1
  done
}

# Repair only the global REAPER directories identified by the installation log.
# Existing directories, valid links and plugin files are preserved.
hook_prepare_reaper_directories "/Library/Application Support/REAPER"
echo
echo "Reparo concluido. Execute novamente o instalador PKG da Hook Center."
echo "Se um link precisou ser substituido, seu backup foi informado acima."
