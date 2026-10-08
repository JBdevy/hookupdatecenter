#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-native-input.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys, uuid
scroll=Path('Apple/Shared/GridScrollView.swift').read_text()
diagnostics=scroll[scroll.index('enum TimelineLayoutDiagnostics'):scroll.index('protocol SidebarResizeLayoutBoundary')]
start=scroll.index('final class GridNativeScrollView: NSScrollView')
end=scroll.index('\n#endif',start)
clip_start=scroll.index('private final class TimelineClipView: NSClipView')
clip_end=scroll.index('\n#endif',clip_start)
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
models=Path('Application/Project/ProjectModels.swift').read_text()
geometry=models[models.index('public enum TrackHeightGeometry'):models.index('public struct TrackLinkOriginal')]
limits=grid[grid.index('enum TimelineZoomLimits'):grid.index('\nprivate let markerLaneHeight')]
test_domain = 'com.hookdeveloper.catlive.viewport.test.' + str(uuid.uuid4())
limits = limits.replace('com.hookdeveloper.catlive.viewport', test_domain)
cleanup = '\ndefer { TimelineViewportPreferences.storage.removePersistentDomain(forName: "' + test_domain + '") }\n'

Path(sys.argv[1]).write_text('import AppKit\n'+diagnostics+'\n'+limits+'\n'+geometry+'\n'+scroll[start:end]+'\n'+scroll[clip_start:clip_end]+cleanup+Path('Tests/Apple/TimelineInputGateTests.swift').read_text())
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/TimelineWheelInput.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
