#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-zoom-coherence.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" "${1:-current}" <<'PY'
from pathlib import Path
import sys
s=Path('Apple/Shared/TimelineGridView.swift').read_text()
a=s.index('private struct TimelineCanvasSurface:')
b=s.index('/// Search sorted item boundaries',a)
part=s[a:b]
if sys.argv[2]=='legacy':
 part=part.replace('documentWidth ?? geometry.size.width','geometry.size.width')
Path(sys.argv[1]).write_text('import SwiftUI\nprivate struct TimelineTileIdentity: Equatable {}\n'+part+'\n'+Path('Tests/Apple/TimelineZoomFrameCoherenceTests.swift').read_text())
PY
swiftc -O -swift-version 5 Apple/Shared/TimelineAudioWaveform.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" "${1:-current}"
