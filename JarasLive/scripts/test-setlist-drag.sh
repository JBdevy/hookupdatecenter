#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-setlist-drag.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYCODE'
from pathlib import Path
import sys
import os
source = Path('Apple/Shared/SongListView.swift').read_text()
start = source.index('private final class SetlistReorderState:')
subject = source[start:source.index('private struct LockedRegionDrag:',start)]
press = source[source.index('private enum SetlistSelectionPhase {'):source.index('private struct RegionSetlistRow:')]
scroll = Path('Apple/Shared/GridScrollView.swift').read_text()
edge = scroll[scroll.index('@MainActor final class NativeDragEdgeScroll'):].split('\n#endif', 1)[0]
typography = '// App-owned typography.' + Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.', 1)[1]
edge = edge.replace('(scroll as? GridNativeScrollView)?.prepareSelectionScroll(to: origin, horizontal: false)', '')
block = source[source.index('private struct SetlistBlockRow:'):source.index('/// Project copies preserve model UUIDs')]
scaling = Path('Apple/Shared/InterfaceScaling.swift').read_text()
scaling = scaling[scaling.index('struct InterfaceScaleLayout<'):scaling.index('private struct InterfaceScaleModifier:')]
if os.environ.get('CATLIVE_SETLIST_DRAG_TRACE') == '1':
 subject = subject.replace('private func handle(_ event: NSEvent) -> Bool {', 'private func handle(_ event: NSEvent) -> Bool {\n print("EVENT ", event.type.rawValue, event.locationInWindow, event.window === pressedRow?.window, pressedRow?.name ?? "none", NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")')
 subject = subject.replace('let text = payload()', 'let text = payload(); print("PAYLOAD", row.name, text)')
 subject = subject.replace('let insertAfter = info.location.y >= height / 2', 'print("PERFORM_DROP", entry, info.location, state.scope ?? "nil", scope); let insertAfter = info.location.y >= height / 2')
subject = '\n'.join([typography, scaling, edge, press, block, subject])
Path(sys.argv[1]).write_text(Path('Tests/Apple/SetlistDragTests.swift').read_text().replace('// INSERT_SETLIST_DRAG',subject))
PYCODE
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
for scale in ${CATLIVE_SETLIST_TEST_SCALES:-1}; do
 CATLIVE_SETLIST_TEST_SCALE="$scale" "$test_dir/test"
done
