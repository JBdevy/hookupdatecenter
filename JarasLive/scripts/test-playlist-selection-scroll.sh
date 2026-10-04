#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-playlist-wheel.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/SongListView.swift').read_text()
start=source.index('private struct PlaylistSelectionClick:')
subject=source[start:source.index('\n#endif',start)]
scroll=Path('Apple/Shared/GridScrollView.swift').read_text()
start=scroll.index('struct SidebarScrollMetrics:')
subject += '\n' + scroll[start:scroll.index('\n#endif',start)]
Path(sys.argv[1]).write_text(Path('Tests/Apple/PlaylistSelectionScrollTests.swift').read_text().replace('// INSERT_PLAYLIST_CLICK_VIEW',subject))
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
