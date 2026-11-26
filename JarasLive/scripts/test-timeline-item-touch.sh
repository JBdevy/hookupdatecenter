#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-touch-item.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder=Path(sys.argv[1])
full=Path('Apple/Shared/GridSelectionInput.swift').read_text()
source=full.split('#if os(macOS)\nimport AppKit')[0]
typography = '// App-owned typography.' + Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.', 1)[1]
source += '\nimport AppKit\nimport CoreText\n'+typography+'\n'+full[full.index('enum GridSelectionHeaderText {'):full.index('private enum GridSelectionHeaderControls {')]
folder.joinpath('metadata.swift').write_text(source)
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
start=grid.index('private struct ClipDragInput: View {')
folder.joinpath('touch.swift').write_text('import SwiftUI\n'+grid[start:grid.index('\n#endif',start)])
folder.joinpath('main.swift').write_text('import AppKit\n'+Path('Tests/Apple/TimelineItemTouchGestureTests.swift').read_text())
PY
swiftc Application/Project/ItemFadeCurve.swift -O -swift-version 5 "$test_dir/metadata.swift" Apple/Shared/TimelineItemTouchGesture.swift "$test_dir/touch.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
