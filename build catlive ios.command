#!/bin/bash
# Kept as an entry point for existing shortcuts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec bash "$ROOT/build catlive app.command" "$@"
