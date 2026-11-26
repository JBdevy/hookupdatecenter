#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-track-colour.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/test.cpp" <<'PY'
from pathlib import Path
import sys
source=Path('Windows/Source/Workspace.cpp').read_text()
start=source.index('void Workspace::editTrack(ID id,')
body=source[start:source.index('void Workspace::editTrackIcon(',start)]
Path(sys.argv[1]).write_text(Path('Tests/Core/WindowsTrackColourTests.cpp').read_text().replace('// INSERT_EDIT_TRACK',body))
PY
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -pedantic -I Core -I Windows/Source "$test_dir/test.cpp" -o "$test_dir/test"
"$test_dir/test"
