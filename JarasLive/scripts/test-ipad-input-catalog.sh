#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-input-catalog.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/AudioDeviceSettings.swift').read_text()
begin = source.index('    private func configureMobileSession(')
methods = source[begin:source.index('    private func observeMobileSession()', begin)]
fixture = Path('Tests/Apple/IpadAudioInputCatalogTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// PRODUCTION_SESSION_METHODS', methods))
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
