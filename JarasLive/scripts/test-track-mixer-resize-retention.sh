#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-retention.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
s=Path('Apple/Shared/TrackMixerRow.swift').read_text()
parts=['import AppKit\nimport SwiftUI\nimport Combine\nimport UniformTypeIdentifiers\n']
for begin,end in [('struct TrackMixerHeightGeometry','\n#endif'),('private struct CompactTrackButtonStyle:','private struct TrackPanFader:'),('private struct DirectVolumeSlider:','\n#endif'),('private struct TrackDragTitle:','\n#endif'),('struct TrackControlSelectionExclusion:','@MainActor final class TrackSelectionRouter')]:
 a=s.index(begin);parts.append(s[a:s.index(end,a)])
m=Path('Apple/Shared/StemAudioPlayback.swift').read_text()
a=m.index('@MainActor final class TrackMeterLevel');parts.append(m[a:m.index('/// Item edges',a)])
a=m.index('/// Uses the existing stereo readings');parts.append(m[a:m.index('private final class PreparedSoundFont',a)])
v=Path('Apple/Shared/TimelineGridView.swift').read_text()
a=v.index('private struct TimelineTrackRowsContainer');parts.append(v[a:v.index('private struct TimelineMixerIdentity',a)])
parts.append('''
private enum AutomationTarget { enum Kind { case pan, volume } }
private final class ShowController: ObservableObject { @Published var snapshot = 0; func automationPlaybackValue(_ track: UUID?, kind: AutomationTarget.Kind) -> Double? { nil } }
private enum JarasTheme { static let green = Color.green; static let yellow = Color.yellow; static let text = Color.white }
private struct TrackControlIdentity: Equatable { let project: UUID; let track: UUID? }
private final class TrackReorderState: ObservableObject { var source: TrackDragSource?; func begin(track: UUID) {} ; func finish() {} }
private final class TrackSelectionRouter { static let shared=TrackSelectionRouter(); var pinnedTracks = Set<UUID>(); func addControl(_ view: NSView) {} ; func perform(track:UUID,event:NSEvent,action:()->Void) { action() } }
private enum Counts { static var origin=0; static var size=0; static var slotLayouts=0; static var update=0; static func reset(){origin=0;size=0;slotLayouts=0;update=0} }
''')
for i,p in enumerate(parts):
 p=p.replace('if view.snapshot !== snapshot {', 'if view.snapshot !== snapshot { Counts.update += 1')
 p=p.replace('private final class TrackMixerControlHost: NSHostingView<AnyView> {', 'private final class TrackMixerControlHost: NSHostingView<AnyView> {\n override func layout() { Counts.slotLayouts += 1; super.layout() }')
 parts[i]=p
parts.append(Path('Tests/Apple/TrackMixerResizeRetentionTests.swift').read_text())
tests=Path('Tests/Apple/TrackMixerNativeControlsTests.swift').read_text()
tests=tests.replace('.buttonStyle(CompactTrackButtonStyle()).background {', '.buttonStyle(CompactTrackButtonStyle()).background(TrackControlSelectionExclusion()).background {')
tests=tests.replace('_ = NSApplication.shared\nif CommandLine.arguments', '_ = NSApplication.shared\nif CommandLine.arguments.contains("--resize-retention") { if CommandLine.arguments.contains("--verify-retention") { verifyDetachedRetention() } else { verifyResizeRetention() }; return }\nif CommandLine.arguments')
parts.append(tests)
source='\n'.join(parts)
# Test-only baseline retains the formerly hidden hosts. Candidate runs the
# production detachment implementation unchanged.
source=source.replace('    private func setHostsAttached(_ attached: Bool) {',
    '    private func setHostsAttached(_ attached: Bool) {\n        if CommandLine.arguments.contains("--keep-offscreen-attached") { return }')
root.joinpath('main.swift').write_text(source)
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift -O -target "$(uname -m)-apple-macos12.0" Apple/Shared/JarasLegacyLayout.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" --resize-retention --verify-retention --behavior
for pass in 1 2 3; do
    "$test_dir/test" --resize-retention --keep-offscreen-attached
    "$test_dir/test" --resize-retention
done
