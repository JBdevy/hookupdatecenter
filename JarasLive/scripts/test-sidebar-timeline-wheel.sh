#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-sidebar-timeline-wheel.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('Apple/Shared/GridScrollView.swift').read_text()
start = source.index('struct SidebarScrollMetrics:')
end = source.index('\n#endif', start)
(folder/'scroll.swift').write_text('import SwiftUI\nimport AppKit\n' + source[start:end])
(folder/'main.swift').write_text(Path('Tests/Apple/SidebarTimelineWheelRoutingTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/scroll.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
