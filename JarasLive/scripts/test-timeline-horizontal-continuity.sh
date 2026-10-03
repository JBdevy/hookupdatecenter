#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-horizontal-continuity.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
surface=grid[grid.index('private struct TimelineCanvasSurface:'):grid.index('/// Search sorted item boundaries')]
limits=grid[grid.index('enum TimelineZoomLimits'):grid.index('\nprivate let markerLaneHeight')]
scroll=Path('Apple/Shared/GridScrollView.swift').read_text()
diagnostics=scroll[scroll.index('enum TimelineLayoutDiagnostics'):scroll.index('protocol SidebarResizeLayoutBoundary')]
a=scroll.index('private final class GridDocumentView:')
native=scroll[a:scroll.index('\n#endif',a)]
a=scroll.index('private final class TimelineClipView:')
clip=scroll[a:scroll.index('\n#endif',a)]
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nprivate struct TimelineTileIdentity: Equatable {}\n'+diagnostics+'\n'+limits+'\n'+native+'\n'+clip+'\n'+surface+'\n'+Path('Tests/Apple/TimelineHorizontalContinuityTests.swift').read_text())
PY
swiftc Apple/Shared/TimelineRenderDiagnostics.swift -swift-version 5 Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/TimelineWheelInput.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
