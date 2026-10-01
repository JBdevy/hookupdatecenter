#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-horizontal-surfaces.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYCODE'
from pathlib import Path
import sys
s=Path('Apple/Shared/TimelineGridView.swift').read_text()
a=s.index('private struct TimelineCanvasSurface:'); b=s.index('/// Search sorted item boundaries',a)
Path(sys.argv[1]).write_text('import SwiftUI\nprivate struct TimelineTileIdentity: Equatable { var revision = 0 }\n'+s[a:b]+Path('Tests/Apple/TimelineHorizontalSurfaceTests.swift').read_text())
PYCODE
swiftc -swift-version 5 Apple/Shared/TimelineAudioWaveform.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
