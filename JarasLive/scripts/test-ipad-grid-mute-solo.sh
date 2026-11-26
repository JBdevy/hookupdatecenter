#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-grid-colors.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/DAWRemoteView.swift').read_text()
def section(start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]
item = section('private struct RemoteNativeGridItem:', '/// A compact inspector')
style = source[source.index('private struct RemoteFullAreaButtonStyle:'):]
style = style[:style.index('\n}\n') + 3]
constants = Path('Apple/Shared/GridSelectionInput.swift').read_text().split('struct GridSelectionItem {', 1)[1].split('    let id:', 1)[0]
stubs = '''
final class RemoteTrackScrollController {}
struct RemoteGridItemHoldProbe: View {
 let controller: RemoteTrackScrollController; let tap: (() -> Void)?; let hold: () -> Void
 var body: some View { Color.clear }
}
struct RemoteNativeItemEditor: View {
 let clip: DAWRemoteState.Clip; let color: UInt32; let setGain: (Double) -> Void
 let mute: () -> Void; let close: () -> Void
 var body: some View { Color.clear }
}
'''
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + Path('Application/Project/TeleprompterSettings.swift').read_text() + '\n' + Path('Apple/Shared/DAWRemoteProtocol.swift').read_text() + '\n' + stubs + '\nstruct GridSelectionItem {\n' + constants + '\n}\n' + style + '\n' + section('private func remoteColor(', '/// Native rectangular fader') + '\n' + item + '\n' + Path('Tests/Apple/IpadGridMuteSoloTests.swift').read_text())
PY
swiftc Application/Project/ItemFadeCurve.swift -swift-version 5 -target "$(uname -m)-apple-macos13.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
