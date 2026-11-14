#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-input-diagnostics.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/GridScrollView.swift').read_text()
start = source.index('enum TimelineLayoutDiagnostics')
end = source.index('/// Opt-in structural snapshot', start)
Path(sys.argv[1]).write_text('import AppKit\n' + source[start:end] + '\n' + Path('Tests/Apple/TimelineInputDiagnosticsTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
env -u CATLIVE_PROFILE_LAYOUT "$test_dir/test"
CATLIVE_PROFILE_LAYOUT=1 "$test_dir/test"
