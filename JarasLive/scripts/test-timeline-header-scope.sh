#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-header-scope.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('private enum TimelineHeaderViewport')
end = source.index('/// Only the horizontal document observes zoom', start)
key_start = source.index('struct TimelineRenderKey:')
key_end = source.index('/// Controls do not need sample arrays', key_start)
snap_start = source.index('    private func itemPosition(')
snap_end = source.index('    private func gridPosition(', snap_start)
snap_probe = '''
private struct HeaderCursorSnapProbe {
    let show: HeaderSnapShow
    let editPosition: Double
''' + source[snap_start:snap_end] + '''
    func gesture() -> () -> Void {
        { _ = itemPosition(20, song: Song(), pixelsPerSecond: 10) }
    }
}
'''
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + source[start:end] + source[key_start:key_end] + snap_probe + Path('Tests/Apple/TimelineHeaderScopeTests.swift').read_text())
PYTHON
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
