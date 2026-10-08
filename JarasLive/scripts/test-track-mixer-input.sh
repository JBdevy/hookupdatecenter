#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-controls.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]);s=Path('Apple/Shared/TrackMixerRow.swift').read_text()
parts=['import AppKit\nimport SwiftUI\nimport Combine\nimport UniformTypeIdentifiers\n']
for begin,end in [('struct TrackMixerHeightGeometry','\n#endif'),('private struct CompactTrackButtonStyle:','private struct TrackPanFader:'),('private struct DirectVolumeSlider:','\n#endif'),('private struct TrackDragTitle:','\n#endif')]:
 a=s.index(begin);parts.append(s[a:s.index(end,a)])
m=Path('Apple/Shared/StemAudioPlayback.swift').read_text()
a=m.index('@MainActor final class TrackMeterLevel');parts.append(m[a:m.index('/// Item edges',a)])
a=m.index('/// Uses the existing stereo readings');parts.append(m[a:m.index('private final class PreparedSoundFont',a)])
v=Path('Apple/Shared/TimelineGridView.swift').read_text()
a=v.index('private struct TimelineTrackRowsContainer');parts.append(v[a:v.index('private struct TimelineMixerIdentity',a)])
parts.append('''
private enum JarasTheme { static let green = Color.green; static let yellow = Color.yellow; static let text = Color.white }
private struct TrackControlIdentity: Equatable { let project: UUID; let track: UUID? }
private final class TrackReorderState: ObservableObject { var source: TrackDragSource?; func begin(track: UUID) {} ; func finish() {} }
private final class TrackSelectionRouter { static let shared=TrackSelectionRouter(); var pinnedTracks = Set<UUID>(); func addControl(_ view: NSView) {} ; func perform(track:UUID,event:NSEvent,action:()->Void) { action() } }
private enum Counts { static var origin=0; static var size=0; static var slotLayouts=0; static var update=0; static func reset(){origin=0;size=0;slotLayouts=0;update=0} }
''')
# Count only calls from the actual native implementations, without changing behavior.
for i,p in enumerate(parts):
 for klass in ['DirectVolumeSliderView','TrackDragTitleView','NativeVerticalTrackMeterView']:
  token='final class '+klass+': NSView {'
  p=p.replace(token,token+'''
    override func setFrameOrigin(_ origin: NSPoint) { if frame.origin != origin { Counts.origin += 1 }; super.setFrameOrigin(origin) }
    override func setFrameSize(_ size: NSSize) { if frame.size != size { Counts.size += 1 }; super.setFrameSize(size) }
''')
 p=p.replace('if view.snapshot !== snapshot {', 'if view.snapshot !== snapshot { Counts.update += 1')
 p=p.replace('private final class TrackMixerControlHost: NSHostingView<AnyView> {', 'private final class TrackMixerControlHost: NSHostingView<AnyView> {\n override func layout() { Counts.slotLayouts += 1; super.layout() }')
 parts[i]=p

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
gate=Path('Apple/Shared/NativeTimelineInputGate.swift').read_text()
gate=gate.replace('private static let inputs =', 'static var testEnabled = true\n    private static let inputs =')
gate=gate.replace('guard let window = host.window', 'guard testEnabled else { return nil }\n        guard let window = host.window')
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
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos12.0" Apple/Shared/JarasLegacyLayout.swift "$test_dir/Gate.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" --shortcut
