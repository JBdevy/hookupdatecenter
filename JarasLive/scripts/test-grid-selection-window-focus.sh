#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-window-focus.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys

def section(source, marker):
    start = source.index(marker)
    return source[start:source.index('\n#endif', start)]

scroll = Path('Apple/Shared/GridScrollView.swift').read_text()
rows = Path('Apple/Shared/TrackMixerRow.swift').read_text()
typography = '// App-owned typography.' + Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.', 1)[1]
controls = '@MainActor final class ControlMappings { static let shared = ControlMappings(); var editing: Int?; func handleKey(_ event: NSEvent) -> Bool { false } }'
sources = [
    'import SwiftUI', typography, controls,
    section(rows, 'struct EditorSelectionArea:'),
    scroll[scroll.index('enum TimelineLayoutDiagnostics'):scroll.index('protocol SidebarResizeLayoutBoundary')],
    section(scroll, 'final class GridNativeScrollView'),
    section(scroll, 'final class NativeTimelinePinnedView'),
    section(Path('Apple/Shared/TimelineGridView.swift').read_text(), 'final class RegionShortcutView:'),
    section(Path('Apple/Shared/SongListView.swift').read_text(), 'final class SetlistKeyView:'),
    Path('Tests/Apple/GridSelectionWindowFocusTests.swift').read_text(),
]
Path(sys.argv[1]).write_text('\n'.join(sources))
PY
python3 scripts/track-height-test-geometry.py "$test_dir/TrackHeightGeometry.swift"
swiftc "$test_dir/TrackHeightGeometry.swift" Application/Project/ItemFadeCurve.swift -swift-version 5 \
    Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift \
    Apple/Shared/GridSelectionInput.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
