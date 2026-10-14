#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-route-recovery.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/AppContainer.swift').read_text()
start = source.index('    private func handleMobileAudioEvent(')
methods = source[start:source.index('    #endif\n    func start()', start)]
fixture = Path('Tests/Apple/IpadRouteRecoveryTests.swift').read_text()
recording = Path('Apple/Shared/TrackRecording.swift').read_text()
begin = recording.index('    func finishAndWait() async {')
wait = recording[begin:recording.index('    func finish() {', begin)]
Path(sys.argv[1]).write_text(fixture.replace('// PRODUCTION_RECOVERY_METHODS', methods).replace('// PRODUCTION_FINISH_AND_WAIT', wait))
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
