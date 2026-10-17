#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-fader.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Apple/Shared/TrackMixerRow.swift').read_text()
start = source.index('private struct FooterMixerGainReadout:')
end = source.index('\n#endif', start)
tests = Path('Tests/Apple/FaderInteractionTests.swift').read_text()
fadeout = Path('Application/Transport/TransportFadeout.swift').read_text().split('extension ShowController {')[0]
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nimport Combine\nprivate enum AutomationTarget { enum Kind { case pan, volume } }\n@MainActor private final class ShowController: ObservableObject { let transportFadeout = TransportFadeout(); var projectSessionID = UUID(); @Published var snapshot = 0; func automationPlaybackValue(_ track: UUID?, kind: AutomationTarget.Kind) -> Double? { nil } }\nprivate struct TrackControlIdentity: Equatable { let project: UUID; let track: UUID? }\nprivate enum JarasTheme { static let green = Color.green; static let yellow = Color.yellow }\n' + ('// App-owned typography.' + Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.')[1]) + '\n' + fadeout + '\n' + source[start:end] + '\n' + tests)
PYTHON
swift "$build_dir/main.swift"
