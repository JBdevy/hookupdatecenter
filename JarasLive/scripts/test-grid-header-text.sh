#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-grid-header-text.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/GridSelectionInput.swift').read_text()
item=source[source.index('struct GridSelectionItem {'):source.index('/// Immutable item metadata')]
cache=source[source.index('enum GridSelectionHeaderText {'):source.index('struct GridSelectionInput: NSViewRepresentable')]
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\n'+item+'\n'+cache+'\n'+Path('Tests/Apple/GridHeaderTextTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
