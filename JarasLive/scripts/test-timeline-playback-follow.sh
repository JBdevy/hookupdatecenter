#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-playback-follow.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
scroll = Path('Apple/Shared/GridScrollView.swift').read_text()
diagnostics = scroll[scroll.index('enum TimelineLayoutDiagnostics'):scroll.index('protocol SidebarResizeLayoutBoundary')]
diagnostics += scroll[scroll.index('struct GridRowReveal:'):scroll.index('/// The grid owns these scroll views.')]
diagnostics += scroll[scroll.index('enum TimelineVerticalBar {'):scroll.index('struct GridScrollView<')]
diagnostics += '\nprivate final class GridDocumentView: NSView { var followsViewportWidth = false; func synchronizeHostedViewport() {} }\n'
pads = Path('Apple/Shared/VinhetasPanel.swift').read_text()
diagnostics += pads[pads.index('enum LibrarySamplerTransfer {'):pads.index('enum PadAudioBuffer {')]
diagnostics += """
typealias MixerDividerView = NSView
private protocol TimelineSetlistResizeHost: AnyObject {
    var trailingSetlistDivider: MixerDividerView? { get }
}
"""
start = scroll.index('final class GridNativeScrollView: NSScrollView')
native = scroll[start:scroll.index('\n#endif', start)]
start = scroll.index('private final class TimelineClipView: NSClipView')
clip = scroll[start:scroll.index('\n#endif', start)]
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nimport UniformTypeIdentifiers\n' + diagnostics + '\n' + native + '\n' + clip + '\n' + Path('Tests/Apple/TimelinePlaybackFollowTests.swift').read_text())
PY
python3 scripts/track-height-test-geometry.py "$test_dir/TrackHeightGeometry.swift"
swiftc "$test_dir/TrackHeightGeometry.swift" -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/TimelinePlaybackFollow.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
