#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-needles.XXXXXX")"
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
start = grid.index('/// Moving needles update Core Animation layers')
layer = grid[start:grid.index('private struct TimelineCursorAppearance<', start)].rsplit('#endif', 1)[0]
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
stubs = Path('Tests/Apple/TimelinePlaybackLayerTests.swift').read_text().split('@MainActor private final class PresentationJournal')[0]
stubs = stubs.replace('let duration: Double; let parts:', 'let id = UUID(); let duration: Double; let parts:')
stubs = stubs.replace('var isPlaying: Bool', '@Published var subCursorPreview = false\n    var subCursorVisible: Bool { subCursorPreview || snapshot.transport.subPlay.playing }\n    var isPlaying: Bool')
stubs += '''
@MainActor private final class AppearanceColor: ObservableObject {
    static var colors: [String: AppearanceColor] = [:]
    @Published var value: Int
    init(_ value: Int) { self.value = value }
    static func shared(_ key: String, default fallback: Int) -> AppearanceColor {
        if let existing = colors[key] { return existing }
        let color = AppearanceColor(fallback); colors[key] = color; return color
    }
}
private enum TimelineAppearanceDefaults { static let playCursor = 0x7548dd, editCursor = 0xb9e229, subPlayCursor = 0xff6f00 }
private enum JarasLocalization { static func string(_ value: String) -> String { value } }
'''
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nimport Combine\n' +
    stub_track + transport + '\n' + multi + '\n' + diagnostics + '\n' + native + '\n' + clip + '\n' +
    layer + '\n' + stubs + '\n' + Path('Tests/Apple/NativeTimelineNeedlesTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/Presentation.swift" \
    Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/TimelinePlaybackFollow.swift \
    "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
