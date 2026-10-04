#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-track-name-contrast.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
theme = Path('Apple/Shared/Theme.swift').read_text()
start = theme.index('enum TrackNameContrast {')
helper = theme[start:theme.index('\nextension Color', start)]
row = Path('Apple/Shared/TrackMixerRow.swift').read_text()
start = row.index('private struct TrackDragTitle:')
native_title = row[start:row.index('\n#endif', start)]
stubs = '''import AppKit
import SwiftUI
final class TrackReorderState: NSObject {
 var source: NSObject?
 func begin(track: UUID) {}
 func finish() {}
}
final class TrackSelectionRouter {
 static let shared = TrackSelectionRouter()
 func perform(track: UUID, event: NSEvent, _ action: () -> Void) { action() }
}
'''
Path(sys.argv[1]).write_text(stubs + helper + '\n' + native_title + '\n' + Path('Tests/Apple/TrackNameContrastTests.swift').read_text())
PY
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
