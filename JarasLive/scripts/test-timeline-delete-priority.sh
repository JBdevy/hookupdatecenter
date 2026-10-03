#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-delete-priority.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
timeline = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = timeline.index('final class RegionShortcutView:')
grid = timeline[start:timeline.index('\n#endif', start)]
setlist = Path('Apple/Shared/SongListView.swift').read_text()
start = setlist.index('final class SetlistKeyView:')
listing = setlist[start:setlist.index('\n#endif', start)]
# Keep this event-routing test independent of whichever app is frontmost.
listing = listing.replace('guard NSApp.isActive, let window', 'guard let window')
tests = Path('Tests/Apple/TimelineDeletePriorityTests.swift').read_text()
Path(sys.argv[1]).write_text(tests.replace('// INSERT_NATIVE_DELETE_HANDLERS', grid + '\n' + listing))
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
