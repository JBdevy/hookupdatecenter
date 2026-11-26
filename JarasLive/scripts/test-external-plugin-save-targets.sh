#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
capture_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-plugin-save.XXXXXX")"
trap 'rm -rf "$capture_test_dir"' EXIT
python3 - "$capture_test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/ExternalPluginEditor.swift').read_text()
start = source.index('    static func captureAllForSaving(show: ShowController) throws {')
end = source.index('    static func bindEdits(', start)
fixture = Path('Tests/Apple/ExternalPluginSaveTargetsTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('PRODUCTION_CAPTURE_ALL', source[start:end]))
PY
swiftc -O -swift-version 5 "$capture_test_dir/main.swift" -o "$capture_test_dir/test"
"$capture_test_dir/test"
