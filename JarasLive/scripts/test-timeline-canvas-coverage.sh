#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-canvas-coverage.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('private enum TimelineCanvasCoverage {')
end = source.index('private struct ViewportTimelineCanvas:', start)
Path(sys.argv[1]).write_text('import Foundation\nimport CoreGraphics\n' + source[start:end] + '\n' + Path('Tests/Apple/TimelineCanvasCoverageTests.swift').read_text())
PY
swiftc -O "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
