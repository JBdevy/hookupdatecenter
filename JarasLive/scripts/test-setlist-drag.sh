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
press = source[source.index('private enum SetlistSelectionPhase {'):source.index('private struct RegionSetlistRow:')]
scroll = Path('Apple/Shared/GridScrollView.swift').read_text()
edge = scroll[scroll.index('@MainActor final class NativeDragEdgeScroll'):].split('\n#endif', 1)[0]
typography = '// App-owned typography.' + Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.', 1)[1]
edge = edge.replace('(scroll as? GridNativeScrollView)?.prepareSelectionScroll(to: origin, horizontal: false)', '')
subject = '\n'.join([typography, edge, press, subject])
Path(sys.argv[1]).write_text(Path('Tests/Apple/SetlistDragTests.swift').read_text().replace('// INSERT_SETLIST_DRAG',subject))
PYCODE
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
