#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-fader.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Apple/Shared/TrackMixerRow.swift').read_text()
theme = Path('Apple/Shared/Theme.swift').read_text()
meter = Path('Apple/Shared/StemAudioPlayback.swift').read_text()
start = source.index('private struct FooterMixerGainReadout:')
end = source.index('\n#endif', start)
tests = Path('Tests/Apple/FaderInteractionTests.swift').read_text()
fadeout = Path('Application/Transport/TransportFadeout.swift').read_text().split('extension ShowController {')[0]
pan_label = source.index('func mixerPanText(')
pan_face = source.index('enum MixerPanFace')
tooltip = source.index('@MainActor private final class CompactTrackValueTooltip')
color = theme.index('extension Color {')
parts = [
    'import AppKit\nimport SwiftUI\nimport Combine',
    '''private enum AutomationTarget { enum Kind { case pan, volume } }
@MainActor private final class ShowController: ObservableObject {
    let transportFadeout = TransportFadeout()
    let multiLoopFaders = MultiLoopFaderPresentation()
    var projectSessionID = UUID()
    @Published var snapshot = 0
    func automationPlaybackValue(_ track: UUID?, kind: AutomationTarget.Kind) -> Double? { nil }
}
private struct TrackControlIdentity: Equatable { let project: UUID; let track: UUID? }
private enum JarasTheme {
    static let green = Color.green
    static let yellow = Color.yellow
    static let displayHex: UInt32 = 0x0f0f0f
    static let lightDarkBackgroundHex: UInt32 = 0x242424
    static let workspaceToolbar = Color.gray
}''',
    theme[theme.index('enum JarasInterfaceTheme:'):theme.index('enum JarasTheme {')],
    theme[color:theme.index('\n}', color) + 2],
    theme[theme.index('// App-owned typography.'):],
    meter[meter.index('@MainActor final class TrackMeterLevel:'):meter.index('struct MixerFaderMeter:')],
    source[source.index('enum MixerFaderThumbStyle {'):source.index('private struct TrackVolumeFader:')],
    source[pan_face:source.index('\n}', pan_face) + 2],
    source[pan_label:source.index('\n}', pan_label) + 2],
    '''private enum GridSelectionHeaderControls {
    static func drawValueTooltip(_ text: String, in bounds: CGRect) {}
}''',
    source[tooltip:source.index('\n#endif', tooltip)],
    fadeout, source[start:end], tests,
]
Path(sys.argv[1]).write_text('\n'.join(parts))
PYTHON
swift "$build_dir/main.swift"
