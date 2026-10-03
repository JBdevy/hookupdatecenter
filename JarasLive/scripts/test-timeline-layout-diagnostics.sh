#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-layout-diagnostics.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
s=Path('Apple/Shared/GridScrollView.swift').read_text()
diagnostics=s[s.index('enum TimelineLayoutDiagnostics'):s.index('private struct WorkspaceHostingIdentity')]
host=s[s.index('private final class GridHostingView'):s.index('final class GridNativeScrollView')]
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n'+diagnostics+'\n'+host+'\n'+Path('Tests/Apple/TimelineLayoutDiagnosticsTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
env -u CATLIVE_PROFILE_LAYOUT "$test_dir/test"
CATLIVE_PROFILE_LAYOUT=1 "$test_dir/test"
