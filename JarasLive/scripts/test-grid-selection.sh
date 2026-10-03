#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-grid-selection.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
scroll = Path('Apple/Shared/GridScrollView.swift').read_text()
diagnostics = scroll[scroll.index('enum TimelineLayoutDiagnostics'):scroll.index('protocol SidebarResizeLayoutBoundary')]
def native_class(name):
    start = scroll.index('final class ' + name)
    return scroll[start:scroll.index('\n#endif', start)]
Path(sys.argv[1]).write_text('import AppKit\n' + diagnostics + '\n' + native_class('GridNativeScrollView') + '\n' + native_class('NativeTimelinePinnedView') + '\n' + Path('Tests/Apple/GridSelectionTests.swift').read_text())
PY
swiftc -swift-version 5 Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/GridSelectionInput.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
