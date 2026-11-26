#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-parts-scrollbar.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
scroll = Path('Apple/Shared/GridScrollView.swift').read_text()
start = scroll.index('struct SidebarScrollMetrics:')
scroll = scroll[start:scroll.index('\n#endif', start)]
parts = Path('Apple/Shared/SmoothSeekPanel.swift').read_text()
start = parts.index('private struct PartsScrollbar:')
parts = parts[start:parts.index('private struct NativeSectionProgressBar:', start)]
parts = parts.replace('private var thumb:', 'fileprivate var thumb:')
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + scroll + '\n' + parts + '\n' + Path('Tests/Apple/PartsScrollbarTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
