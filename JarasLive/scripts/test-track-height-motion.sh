#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-height-motion.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1])
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
wheel=Path('Apple/Shared/TimelineWheelInput.swift').read_text()
limits=grid[grid.index('enum TimelineTrackHeightLimits'):grid.index('private let markerLaneHeight')]
motion=wheel[wheel.index('/// Apply the wheel'):wheel.index('/// Command/Control')]
target=wheel[wheel.index('private final class TimelineDisplayLinkTarget'):wheel.index('/// Limited to the numbered ruler')]
(out/'motion.swift').write_text('import SwiftUI\nimport AppKit\nimport QuartzCore\n'+limits+motion+target)
(out/'main.swift').write_text(Path('Tests/Apple/TimelineTrackHeightMotionTests.swift').read_text())
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift "$test_dir/motion.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
