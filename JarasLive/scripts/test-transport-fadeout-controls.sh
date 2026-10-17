#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-fadeout-controls.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/TrackMixerRow.swift').read_text()
a=source.index('private struct DirectVolumeSlider:')
controls=source[a:source.index('\n#endif',a)]
model=Path('Application/Transport/TransportFadeout.swift').read_text().split('extension ShowController {')[0]
stubs='''
private enum AutomationTarget { enum Kind { case pan, volume } }
@MainActor private final class ShowController: ObservableObject {
    let transportFadeout = TransportFadeout()
    var projectSessionID = UUID()
    @Published var snapshot = 0
    func automationPlaybackValue(_ track: UUID?, kind: AutomationTarget.Kind) -> Double? { nil }
}
private enum JarasTheme { static let green = Color.green; static let yellow = Color.yellow }
private struct TrackControlIdentity: Equatable { let project: UUID; let track: UUID? }
'''
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nimport Combine\n'+model+stubs+('// App-owned typography.' + Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.')[1])+controls+'\n'+Path('Tests/Apple/TransportFadeoutControlTests.swift').read_text())
PY
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos12.0" Apple/Shared/JarasLegacyLayout.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
