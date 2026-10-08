#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement active; native needle fixture deferred." >&2
  exit 2
fi
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
start = scroll.index('final class NativeTimelinePinnedView: NSView')
pin = scroll[start:scroll.index('\n#endif', start)]
grid = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = grid.index('/// Moving needles update Core Animation layers')
layer = grid[start:grid.index('private struct TimelineCursorAppearance<', start)].rsplit('#endif', 1)[0]
models = Path('Application/Project/ProjectModels.swift').read_text()
transport = models[models.index('public struct QueueState:'):models.index('public struct AudioRoute:')]
multi = Path('Application/Project/MultiLoop.swift').read_text()
start = multi.index('public struct MultiLoopPlayback:')
multi = multi[start:multi.index('\n}', start) + 2]
# Only the track payload type is irrelevant to this view; all transport fields,
# the presentation helper, the SwiftUI layer and native follow remain real code.
presentation = Path('Application/Transport/TimelinePlaybackPresentation.swift').read_text().split('/// Song names and explicit tempo metadata')[0]
Path(sys.argv[1]).with_name('Presentation.swift').write_text(presentation)
stub_track = 'public struct MultiLoopTrack: Codable, Equatable, Sendable {}\n'
stubs = Path('Tests/Apple/TimelinePlaybackLayerTests.swift').read_text().split('@MainActor private final class PresentationJournal')[0]
stubs = stubs.replace('let duration: Double; let parts:', 'let id = UUID(); let duration: Double; let parts:')
stubs = stubs.replace('var isPlaying: Bool', '@Published var subCursorPreview = false\n    var timelineFollowPaused = false\n    var subCursorVisible: Bool { subCursorPreview || snapshot.transport.subPlay.playing }\n    var isPlaying: Bool')
stubs = stubs.replace('    private var sampledAt =', '    var timelinePlaybackIsPublishingTick = false\n    private var sampledAt =', 1)
stubs = stubs.replace('subPlaying: Bool = false) {', 'subPlaying: Bool = false, tick: Bool = false) {', 1)
stubs = stubs.replace('        generation += 1', '        timelinePlaybackIsPublishingTick = tick\n        defer { timelinePlaybackIsPublishingTick = false }\n        generation += 1', 1)
layer = layer.replace('    private func paint() {', '    var paintCountForTest = 0\n    private func paint() {\n        paintCountForTest += 1', 1)
layer = layer.replace('        let resized = self.size != size', '        configureCountForTest += 1\n        let resized = self.size != size', 1)
layer = layer.replace('    private var pendingSample = false', '    var configureCountForTest = 0\n    private var pendingSample = false', 1)
layer += '''
extension NativeTimelineNeedlesView {
    var hasTimerForTest: Bool { timer != nil }
    var timerIntervalForTest: Double? { timer?.timeInterval }
    var sampleTimeForTest: Double { sampledAt }
    func freezeTimerForTest() { timer?.fireDate = .distantFuture }
    func fireFrameForTest() { timer?.fire() }
}
'''
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
producer = Path('Application/AppState/ShowController.swift').read_text()
flags = producer[producer.index('    private var updatingPlaybackSnapshot'):producer.index('    @Published public private(set) var snapshot:')]
getter_start = producer.index('    var timelinePlaybackIsPublishingTick:')
getter = producer[getter_start:producer.index('\n', getter_start)]
tick_start = producer.index('    public func tick() {')
tick = producer[tick_start:producer.index('    private var tempoControlRegion:', tick_start)]
auto_fader = Path('Tests/Apple/NativeTimelineNeedlesAutoFaderTests.swift').read_text().replace('__PRODUCTION_FLAGS__', flags).replace('__PRODUCTION_GETTER__', getter).replace('__PRODUCTION_TICK__', tick)
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nimport Combine\n' +
    stub_track + transport + '\n' + multi + '\n' + diagnostics + '\n' + native + '\n' + clip + '\n' + pin + '\n' +
    layer + '\n' + stubs + '\n' + Path('Tests/Apple/NativeTimelineNeedlesTests.swift').read_text() +
    Path('Tests/Apple/NativeTimelineNeedlesCadenceTests.swift').read_text() + auto_fader)
PY
swiftc -swift-version 5 "$test_dir/Presentation.swift" \
    Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/TimelinePlaybackFollow.swift \
    "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
