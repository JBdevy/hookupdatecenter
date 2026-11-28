#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-horizontal-surfaces.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYCODE'
from pathlib import Path
import sys
s=Path('Apple/Shared/TimelineGridView.swift').read_text()
start = s.index('private struct TimelineTileIdentity:')
end = s.index('/// Search sorted item boundaries', start)
drawing = s[s.index('struct TimelineDrawing:'):s.index('/// Metal owns its readiness observer')]
start_call = drawing.index('TimelineTileIdentity(')
# Use the same item-Canvas key and draw inputs as the timeline.
level = 1
cursor = start_call + len('TimelineTileIdentity(')
while level:
    level += (drawing[cursor] == '(') - (drawing[cursor] == ')')
    cursor += 1
item_key = drawing[start_call:cursor]
fixture = Path('Tests/Apple/TimelineHorizontalSurfaceTests.swift').read_text().replace('__ITEM_CANVAS_IDENTITY__', item_key)
Path(sys.argv[1]).write_text('import SwiftUI\n' + s[start:end] + fixture)

PYCODE
swiftc Application/Project/LinkedStemMedia.swift Apple/Shared/TimelineRenderDiagnostics.swift -swift-version 5 Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
