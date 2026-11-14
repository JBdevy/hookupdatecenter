#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-recording-presentation.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TrackRecording.swift').read_text()
start = source.index('    @Published private(set) var armed:')
properties = source[start:source.index('    private var microphoneTracks:', start)]
start = source.index('    private func selectionChanged(')
selection = source[start:source.index('    var recordingDisplayPosition', start)].replace('private func', 'func')
model = Path('Application/Controls/RecordingArmState.swift').read_text()
model = model[model.index('public struct RecordingArmState:'):]
fixture = Path('Tests/Apple/RecordingPresentationTests.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\n' + model + '\n' +
    fixture.replace('    /* RECORDING_PROPERTIES */', properties).replace('    /* RECORDING_SELECTION */', selection))
PY
swiftc -O -swift-version 5 -target "${CATLIVE_TEST_ARCH:-$(uname -m)}-apple-macos12.0" "$build_dir/main.swift" -o "$build_dir/test"
if [[ "${1:-}" == "--build-only" ]]; then
    cp "$build_dir/test" "${2:?Specify the output binary path}"
else
    "$build_dir/test"
fi
