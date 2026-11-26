#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-grid-selection.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
scroll = Path('Apple/Shared/GridScrollView.swift').read_text()
diagnostics = scroll[scroll.index('enum TimelineLayoutDiagnostics'):scroll.index('protocol SidebarResizeLayoutBoundary')]
diagnostics += scroll[scroll.index('struct GridRowReveal:'):scroll.index('/// The grid owns these scroll views.')]
diagnostics += scroll[scroll.index('enum TimelineVerticalBar {'):scroll.index('struct GridScrollView<')]
diagnostics += '\nprivate final class GridDocumentView: NSView { var followsViewportWidth = false; func synchronizeHostedViewport() {} }\n'
# The fixture exercises grid gestures with no attached setlist resize host.
diagnostics += "\nprivate final class MixerDividerView: NSView {}\n"
diagnostics += scroll[scroll.index('private protocol TimelineSetlistResizeHost:'):scroll.index('private final class WorkspaceSplitView<')]
def native_class(name):
    start = scroll.index('final class ' + name)
    return scroll[start:scroll.index('\n#endif', start)]
row_source = Path('Apple/Shared/TrackMixerRow.swift').read_text()
head_start = row_source.index('final class ProgramChangeHeadInputView:')
head_source = row_source[head_start:row_source.index('\n#else', head_start)]
router = row_source
start = router.index('struct EditorSelectionArea: NSViewRepresentable {')
router = router[start:router.index('\n#endif', start)]
controls = '@MainActor final class ControlMappings { static let shared = ControlMappings(); var editing: Int? }\n'
theme = Path('Apple/Shared/Theme.swift').read_text()
colors = theme[theme.index('extension Color {'):theme.index('\n#if os(macOS)\nenum DesktopToolbarTone')]
typography = colors + '\n// App-owned typography.' + theme.split('// App-owned typography.', 1)[1]
pads = Path('Apple/Shared/VinhetasPanel.swift').read_text()
sample_transfer = pads[pads.index('enum LibrarySamplerTransfer'):pads.index('enum PadAudioBuffer')]
Path(sys.argv[1]).write_text('import SwiftUI\nimport UniformTypeIdentifiers\n' + typography + '\n' + sample_transfer + controls + router + '\n' + head_source + '\n' + diagnostics + '\n' + native_class('GridNativeScrollView') + '\n' + native_class('NativeTimelinePinnedView') + '\n' + Path('Tests/Apple/GridSelectionTests.swift').read_text())
PY
python3 scripts/track-height-test-geometry.py "$test_dir/TrackHeightGeometry.swift"
swiftc "$test_dir/TrackHeightGeometry.swift" Application/Project/ItemFadeCurve.swift -swift-version 5 Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/GridSelectionInput.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
