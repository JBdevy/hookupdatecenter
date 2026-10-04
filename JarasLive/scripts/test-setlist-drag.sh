#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-setlist-drag.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYCODE'
from pathlib import Path
import sys
source = Path('Apple/Shared/SongListView.swift').read_text()
start = source.index('private final class SetlistReorderState:')
subject = source[start:source.index('private struct LockedRegionDrag:',start)]
Path(sys.argv[1]).write_text(Path('Tests/Apple/SetlistDragTests.swift').read_text().replace('// INSERT_SETLIST_DRAG',subject))
PYCODE
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
