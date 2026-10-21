#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-selection-height.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/GridSelectionInput.swift').read_text()
start = source.index('struct GridSelectionItem {')
typography = '// App-owned typography.' + Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.', 1)[1]
metrics = '\nimport AppKit\nimport CoreText\n'+typography+'\n'+source[source.index('enum GridSelectionHeaderText {'):source.index('private enum GridSelectionHeaderControls {')]
selection = source[start:source.index('#if os(macOS)\nimport AppKit', start)]
grid = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = grid.index('@MainActor private final class TimelineSelectionLayoutCache {')
cache = grid[start:grid.index('\n#endif', start)]
prefix = 'import AppKit\nimport SwiftUI\nstruct TimelineRenderKey: Equatable { let revision: Int }\n'
Path(sys.argv[1]).write_text(prefix + selection + metrics + cache + '\n' + Path('Tests/Apple/GridSelectionHeightTests.swift').read_text())
PY
swiftc Application/Project/ItemFadeCurve.swift -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
