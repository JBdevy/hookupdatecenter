#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-controls.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, 'scripts')
from native_mixer_test_sources import native_mixer_sources
root=Path(sys.argv[1]);s=Path('Apple/Shared/TrackMixerRow.swift').read_text()
parts=native_mixer_sources(control_marker=False, scroll_stub=False)
a=s.index('struct TrackControlSelectionExclusion: NSViewRepresentable')
marker=s[a:s.index('@MainActor final class TrackSelectionRouter',a)]
marker=marker.replace('private weak var mixerInput:', '''var recordedCursorRects: [(NSRect, NSCursor)] = []
    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) { recordedCursorRects.append((rect, cursor)); super.addCursorRect(rect, cursor: cursor) }
    override func discardCursorRects() { recordedCursorRects.removeAll(); super.discardCursorRects() }
    private weak var mixerInput:''')
parts.append(marker)
scroll=Path('Apple/Shared/GridScrollView.swift').read_text()
a=scroll.index('enum TimelineLayoutDiagnostics');parts.append(scroll[a:scroll.index('protocol SidebarResizeLayoutBoundary',a)])
a=scroll.index('final class GridNativeScrollView: NSScrollView');parts.append(scroll[a:scroll.index('\n#endif',a)])
parts.append(scroll[scroll.index('struct GridRowReveal:'):scroll.index('/// The grid owns these scroll views.')])
# This fixture mounts a plain NSView document. The actual hosted viewport
# synchronization is exercised by test-native-workspace.sh.
parts.append('final class GridDocumentView: NSView { var followsViewportWidth = false; func synchronizeHostedViewport() {} }')
gate=Path('Apple/Shared/NativeTimelineInputGate.swift').read_text()
gate=gate.replace('private static let inputs =', 'static var testEnabled = true\n    private static let inputs =')
gate=gate.replace('guard let window = host.window, !host.isHiddenOrHasHiddenAncestor', 'guard testEnabled else { return nil }\n        guard let window = host.window, !host.isHiddenOrHasHiddenAncestor')
root.joinpath('Gate.swift').write_text(gate)
fixture=Path('Tests/Apple/TrackMixerNativeControlsTests.swift').read_text().split('@MainActor private func run()')[0]
# Share the existing genuine SwiftUI controls; add only real production input
# markers and a native shortcut boundary around that fixture's scroll view.
fixture=fixture.replace('.buttonStyle(CompactTrackButtonStyle()).background { if CommandLine.arguments', '.buttonStyle(CompactTrackButtonStyle()).background(TrackControlSelectionExclusion()).background { if CommandLine.arguments')
fixture=fixture.replace('}.clipped().jarasPlaced(at: 4)', '}.background(TrackControlSelectionExclusion()).clipped().jarasPlaced(at: 4)')
fixture=fixture.replace('let scroll = NSScrollView(frame:', 'let scroll = GridNativeScrollView(frame:')
fixture=fixture.replace('window.contentView = scroll', 'let root = ShortcutHost(frame: scroll.frame)\n        root.addSubview(scroll)\n        window.contentView = root')
parts.append(fixture)
parts.append(Path('Tests/Apple/TrackMixerInputTests.swift').read_text())

root.joinpath('main.swift').write_text('\n'.join(parts))
PY
python3 scripts/track-height-test-geometry.py "$test_dir/TrackHeightGeometry.swift"
swiftc "$test_dir/TrackHeightGeometry.swift" -swift-version 5 -O -target "$(uname -m)-apple-macos12.0" Apple/Shared/JarasLegacyLayout.swift "$test_dir/Gate.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" --shortcut

"$test_dir/test" --shortcut --catlive-test-macos12
