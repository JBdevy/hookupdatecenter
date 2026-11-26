#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-remote-midi.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('Apple/Shared/DAWRemoteView.swift').read_text()
start = source.index('private enum RemoteMIDIAction:')
end = source.index('private struct RemoteMIDIActionsView:', start)
source = source[start:end].replace('catlive.remote.midiActions', 'catlive.remote.midiActions.smoke-test')
Path(sys.argv[1]).write_text('import SwiftUI\nimport CoreMIDI\n' + source + Path('Tests/Apple/RemoteMIDIActionsTests.swift').read_text())
PYTEST
swiftc -swift-version 5 -parse-as-library "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
