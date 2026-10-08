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
private final class TrackSelectionRouter { static let shared=TrackSelectionRouter(); var pinnedTracks = Set<UUID>(); func perform(track:UUID,event:NSEvent,action:()->Void) { action() } }
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
parts.append(Path('Tests/Apple/TrackMixerNativeControlsTests.swift').read_text())
root.joinpath('main.swift').write_text('\n'.join(parts))
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift -O -target "$(uname -m)-apple-macos12.0" Apple/Shared/JarasLegacyLayout.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" --geometry
"$test_dir/test" --behavior
if [[ "${1:-}" == "--benchmark" ]]; then
    "$test_dir/test"
    "$test_dir/test" --candidate
fi
