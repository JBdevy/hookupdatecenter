#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-height.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]);source=Path('Apple/Shared/TrackMixerRow.swift').read_text()
start=source.index('struct TrackMixerHeightGeometry')
root.joinpath('layout.swift').write_text('import SwiftUI\n'+source[start:source.index('\n#endif',start)])
titleStart=source.index('private struct TrackDragTitle:')
title=source[titleStart:source.index('\n#endif',titleStart)].replace('private ', '')
stubs='''
final class NativeVerticalTrackMeterView: NSView {}
final class TrackReorderState: ObservableObject {
 var source: TrackDragSource?
 func begin(track: UUID) {}
 func finish() {}
}
final class TrackSelectionRouter {
 static let shared = TrackSelectionRouter()
 var pinnedTracks = Set<UUID>()
 func perform(track: UUID, event: NSEvent, action: () -> Void) { action() }
}
'''
with root.joinpath('layout.swift').open('a') as f: f.write('\n'+stubs+'\n'+title)
root.joinpath('main.swift').write_text(Path('Tests/Apple/TrackMixerHeightLayoutTests.swift').read_text())
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/JarasLegacyLayout.swift "$test_dir/layout.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
