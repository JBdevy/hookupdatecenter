#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-search-tab.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/SongListView.swift').read_text()
start = source.index('final class SetlistKeyView:')
keys = source[start:source.index('\n#endif', start)]
fixture = Path('Tests/Apple/SetlistSearchTabTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_SEARCH_KEYS', keys))
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
