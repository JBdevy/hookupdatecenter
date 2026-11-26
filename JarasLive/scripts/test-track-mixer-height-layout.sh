#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-height.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]);source=Path('Apple/Shared/TrackMixerRow.swift').read_text()
start=source.index('struct TrackMixerHeightGeometry')
root.joinpath('layout.swift').write_text('import SwiftUI\n'+source[start:source.index('\n/// Content and environment',start)])
main=Path('Apple/Shared/MainView.swift').read_text()
with root.joinpath('layout.swift').open('a') as f:
 f.write('\n'+main[main.index('enum SidebarWidthLimits {'):main.index('private struct FooterDisplayIdentity:')])
titleStart=source.index('private struct TrackDragTitle:')
title=source[titleStart:source.index('\n#endif',titleStart)].replace('fileprivate ', '').replace('private ', '')
stubs='''
private enum JarasTheme { static let text = Color.white }
extension NSFont {
 static func jarasSystemFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
  .systemFont(ofSize: size, weight: weight)
 }
}
final class NativeVerticalTrackMeterView: NSView {}
@MainActor final class NativeDragEdgeScroll { func begin(from: NSView) {} ; func stop() {} }
final class TrackReorderState: ObservableObject {
 var source: TrackDragSource?
 func begin(track: UUID) {}
 func finish() {}
}
final class TrackSelectionRouter {
 static let shared = TrackSelectionRouter()
 weak var editingTitle: TrackDragTitleView?
 func moveRename(from source: TrackDragTitleView, direction: Int) {}
 var pinnedTracks = Set<UUID>()
 func addTitle(_ view: TrackDragTitleView) {}
 func handle(_ event: NSEvent) {} ; func perform(track: UUID, event: NSEvent, action: () -> Void) { action() }
}
'''
theme=Path('Apple/Shared/Theme.swift').read_text()
drawing=theme.index('@MainActor final class NativeScreenDrawing')
with root.joinpath('layout.swift').open('a') as f:
 f.write('\nimport AppKit\n'+theme[drawing:theme.index('\n#endif',drawing)]+'\n'+stubs+'\n'+title)
root.joinpath('main.swift').write_text(Path('Tests/Apple/TrackMixerHeightLayoutTests.swift').read_text())
PY
python3 scripts/track-height-test-geometry.py "$test_dir/TrackHeightGeometry.swift"
swiftc "$test_dir/TrackHeightGeometry.swift" -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/JarasLegacyLayout.swift "$test_dir/layout.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
