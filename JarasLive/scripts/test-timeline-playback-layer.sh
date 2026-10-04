#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-playback-layer.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys

scroll = Path('Apple/Shared/GridScrollView.swift').read_text()
diagnostics = scroll[scroll.index('enum TimelineLayoutDiagnostics'):scroll.index('protocol SidebarResizeLayoutBoundary')]
start = scroll.index('final class GridNativeScrollView: NSScrollView')
native = scroll[start:scroll.index('\n#endif', start)]
start = scroll.index('private final class TimelineClipView: NSClipView')
clip = scroll[start:scroll.index('\n#endif', start)]
grid = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = grid.index('private struct TimelinePlaybackLayer<')
layer = grid[start:grid.index('/// Scrolling updates the small pinned layer', start)]
models = Path('Application/Project/ProjectModels.swift').read_text()
transport = models[models.index('public struct QueueState:'):models.index('public struct AudioRoute:')]
multi = Path('Application/Project/MultiLoop.swift').read_text()
start = multi.index('public struct MultiLoopPlayback:')
multi = multi[start:multi.index('\npublic extension Song', start)]
# Only the track payload type is irrelevant to this view; all transport fields,
# the presentation helper, the SwiftUI layer and native follow remain real code.
presentation = Path('Application/Transport/TimelinePlaybackPresentation.swift').read_text().split('/// Song names and explicit tempo metadata')[0]
Path(sys.argv[1]).with_name('Presentation.swift').write_text(presentation)
stub_track = 'public struct MultiLoopTrack: Codable, Equatable, Sendable {}\n'
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nimport Combine\n' +
    stub_track + transport + '\n' + multi + '\n' + diagnostics + '\n' + native + '\n' + clip + '\n' +
    layer + '\n' + Path('Tests/Apple/TimelinePlaybackLayerTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/Presentation.swift" \
    Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/TimelinePlaybackFollow.swift \
    "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
