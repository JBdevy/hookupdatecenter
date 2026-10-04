#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-track-recycling.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/TrackMixerRow.swift').read_text()
start=source.index('struct TrackControlSelectionExclusion:')
end=source.index('\n#endif',start)
title_start=source.index('private struct TrackDragTitle:')
title_end=source.index('\n#endif',title_start)
stubs='''import SwiftUI
import AppKit
enum TrackKind { case standard, timecode, video, click, other }
final class ControlMappings { static let shared = ControlMappings(); var editing: String? }
private final class TrackReorderState: ObservableObject {
    static let shared = TrackReorderState()
    var active = false
    var source: TrackDragSource?
    private(set) var starts = 0
    func begin(track: UUID) { starts += 1; active = true }
    func finish() { active = false }
}
'''
Path(sys.argv[1]).write_text(stubs+source[start:end]+source[title_start:title_end]+'\n'+Path('Tests/Apple/TrackRowRecyclingTests.swift').read_text())
PY
swiftc -swift-version 5 Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/RightClickRouting.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
