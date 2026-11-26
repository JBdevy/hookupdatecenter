#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-selection-focus.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/router.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/TrackMixerRow.swift').read_text()
start=source.index('struct EditorSelectionArea: NSViewRepresentable {')
source=source[start:source.index('\n#endif',start)]
stubs='''import SwiftUI
@MainActor final class NativeTimelineInputGate {
 static let shared = NativeTimelineInputGate()
 var blocked = false
 func isBlocked(_ window: NSWindow?) -> Bool { blocked }
}
@MainActor final class ControlMappings {
 static let shared = ControlMappings()
 var editing: Int?
}
'''
Path(sys.argv[1]).write_text(stubs+source)
PY
swiftc -swift-version 5 "$test_dir/router.swift" Tests/Apple/EditorSelectionFocusTests.swift -o "$test_dir/test"
"$test_dir/test"
