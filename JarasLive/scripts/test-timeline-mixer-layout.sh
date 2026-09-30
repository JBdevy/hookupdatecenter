#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-mixer-layout.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/TimelineGridView.swift').read_text()
start=source.index('private struct TimelineTrackRowsLayout: Layout {')
end=source.index('private struct TimelineMixerIdentity:',start)
Path(sys.argv[1]).write_text('import SwiftUI\n' + source[start:end] + Path('Tests/Apple/TimelineMixerLayoutTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
