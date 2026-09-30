#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-native-input.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
scroll=Path('Apple/Shared/GridScrollView.swift').read_text()
start=scroll.index('final class GridNativeScrollView: NSScrollView')
end=scroll.index('\n#endif',start)
clip_start=scroll.index('private final class TimelineClipView: NSClipView')
clip_end=scroll.index('\n#endif',clip_start)
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
limits=grid[grid.index('enum TimelineZoomLimits'):grid.index('\nprivate let markerLaneHeight')]
Path(sys.argv[1]).write_text('import AppKit\n'+limits+'\n'+scroll[start:end]+'\n'+scroll[clip_start:clip_end]+'\n'+Path('Tests/Apple/TimelineInputGateTests.swift').read_text())
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/TimelineWheelInput.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
