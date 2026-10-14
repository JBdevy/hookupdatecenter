#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-recording-input.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/Test.swift" <<'PY'
import sys
from pathlib import Path
source = Path('Apple/Shared/TrackRecording.swift').read_text()
start = source.index('    private func configureInput(')
end = source.index('    func open(directory:', start)
methods = source[start:end].replace('private func ', 'func ')
fixture = Path('Tests/Apple/RecordingInputSelectionTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('    /* RECORDING_INPUT_METHODS */', methods))
PY
swiftc -swift-version 6 -parse-as-library "$build_dir/Test.swift" -o "$build_dir/test"
"$build_dir/test"
