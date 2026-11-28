#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-viewport.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/IpadStandaloneWorkspace.swift').read_text()
limits = Path('Apple/Shared/TimelineGridView.swift').read_text().split('enum TimelineZoomLimits {',1)[1].split('enum TimelineTrackHeightLimits',1)[0]
start = source.index('struct IpadTimelineViewport:')
end = source.index('\n/// Recognizers', start)
Path(sys.argv[1]).write_text('import Foundation\nfunc require(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { print(message); exit(1) } }\n' + 'enum TimelineZoomLimits {' + limits + source[start:end] + '\n' + Path('Tests/Apple/IpadStandaloneViewportTests.swift').read_text())
PY
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
