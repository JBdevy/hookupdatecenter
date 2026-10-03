#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-macos12-layout.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
mixer=Path('Apple/Shared/TrackMixerRow.swift').read_text()
start=mixer.index('struct TrackMixerHeightGeometry {')
mixer=mixer[start:mixer.index('\n#endif',start)]
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
start=grid.index('@available(macOS 13, *)\nprivate struct TimelineColumnsLayout:')
grid=grid[start:grid.index('private struct TimelineMixerIdentity:',start)]
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + mixer + '\n' + grid + '\n' + Path('Tests/Apple/MacOS12LayoutTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  Apple/Shared/JarasLegacyLayout.swift \
  "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
"$test_dir/test" --catlive-test-macos12
