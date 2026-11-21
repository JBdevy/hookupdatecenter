#!/bin/bash
set -euo pipefail
cd "${CATLIVE_BOUNDARY_REPO:-$(dirname "$0")/..}"
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; boundary compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-columns-boundary-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import os, sys
grid = Path(os.environ.get('CATLIVE_BOUNDARY_GRID', 'Apple/Shared/GridScrollView.swift')).read_text()
fx = Path('Apple/Shared/FXEditor.swift').read_text().split('enum FXModelLookup')[0]
text = Path('Apple/Shared/TextItemEditor.swift').read_text().split('/// The draft stays')[0]
region = Path('Apple/Shared/RegionEditor.swift').read_text()
start = region.index('struct TrackDetailsEditRequest:')
end = region.index('\n}\n', region.index('extension EnvironmentValues', start)) + 3
environment = fx + text + region[start:end]
timeline = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = timeline.index('struct MixerResizeHandle:')
divider = timeline[start:timeline.index('\n#endif', start)]
theme = Path('Apple/Shared/Theme.swift').read_text()
defaults = theme[theme.index('enum TimelineAppearanceDefaults {'):theme.index('enum TimelineThemeColor:')]
interface = theme[theme.index('enum JarasInterfaceTheme:'):theme.index('\nenum JarasTheme {')]
samplers = Path('Apple/Shared/VinhetasPanel.swift').read_text().split('enum PadAudioBuffer')[0].split('enum LibrarySamplerTransfer ')[1]
grid = grid.replace('enum TimelineLayoutDiagnostics {', """enum TimelineLayoutDiagnostics {
    static var roots: [String: Int] = [:]
    static var layouts: [String: Int] = [:]""")
grid = grid.replace('            var record = makeRecord("layout", view)', '            TimelineLayoutDiagnostics.layouts[role, default: 0] += 1\n            var record = makeRecord("layout", view)')
grid = grid.replace('            roots += 1', '            TimelineLayoutDiagnostics.roots[role, default: 0] += 1\n            roots += 1')
adapters = """
struct GridSelectionInput { func apply(to view: GridSelectionView) {} }
final class GridSelectionView: NSView {}
enum JarasTheme {
    static let setlistQueuedYellow = 0x807219
    static let displayHex: UInt32 = 0x0f0f0f
    static let lightDarkBackgroundHex: UInt32 = 0x242424
    static let workspaceToolbar = Color.gray
}
extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
@MainActor struct NativeLibraryTrackDrop {
    static let type = NSPasteboard.PasteboardType("com.catlive.fixture.effect-drop")
    func operation(for sender: NSDraggingInfo, in view: NSView) -> NSDragOperation { [] }
    func perform(_ sender: NSDraggingInfo, in view: NSView) -> Bool { false }
}
"""
tests = Path(os.environ.get('CATLIVE_BOUNDARY_TEST', 'Tests/Apple/TimelineColumnsBoundaryTests.swift')).read_text()
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\nimport UniformTypeIdentifiers\n' + environment + adapters + interface +
    'enum LibrarySamplerTransfer ' + samplers + grid + '\n' + divider + '\n' + defaults + tests)
PY
python3 scripts/track-height-test-geometry.py "$test_dir/TrackHeightGeometry.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
    Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/RightClickRouting.swift \
    Apple/Shared/JarasLegacyLayout.swift "$test_dir/TrackHeightGeometry.swift" "$test_dir/main.swift" -o "$test_dir/test"
CATLIVE_PROFILE_LAYOUT=1 "$test_dir/test"
