#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; header controls test deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-header-controls.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/GridSelectionInput.swift').read_text()
item = source[source.index('struct GridSelectionItem {'):source.index('/// Immutable item metadata')]
controls_start = source.index('private enum GridSelectionHeaderControls {')
controls = source[controls_start:source.index('/// Editing callbacks read the scale', controls_start)]
methods_start = source.index('    private func drawItemFades(')
methods = source[methods_start:source.index('\n}\n#endif', methods_start)]
methods = methods.replace('private func ', 'static func ')
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\n' + item + '\n' + controls +
    '\nenum CandidateHeaderRenderer {\n' + methods + '\n}\n' +
    Path('Tests/Apple/GridHeaderControlTests.swift').read_text())
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
