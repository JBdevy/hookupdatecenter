#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-touch-item.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder=Path(sys.argv[1])
source=Path('Apple/Shared/GridSelectionInput.swift').read_text().split('#if os(macOS)')[0]
folder.joinpath('metadata.swift').write_text(source)
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
start=grid.index('private struct ClipDragInput: View {')
folder.joinpath('touch.swift').write_text('import SwiftUI\n'+grid[start:grid.index('\n#endif',start)])
folder.joinpath('main.swift').write_text('import AppKit\n'+Path('Tests/Apple/TimelineItemTouchGestureTests.swift').read_text())
PY
swiftc -O -swift-version 5 "$test_dir/metadata.swift" Apple/Shared/TimelineItemTouchGesture.swift "$test_dir/touch.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
