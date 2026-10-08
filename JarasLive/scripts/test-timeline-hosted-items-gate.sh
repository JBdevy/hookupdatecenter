#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; hosted item gate tests deferred." >&2
  exit 2
fi
gate_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-hosted-items-gate.XXXXXX")"
trap 'rm -rf "$gate_test_dir"' EXIT
python3 - "$gate_test_dir/main.swift" <<'PYTHON'
from pathlib import Path
import sys

grid = Path('Apple/Shared/TimelineGridView.swift').read_text()
scroll = Path('Apple/Shared/GridScrollView.swift').read_text()
metal = Path('Apple/Shared/TimelineMetalWaveforms.swift').read_text()

def declaration(source, needle):
    start = source.index(needle)
    start = source.rfind('\n', 0, start) + 1
    end = source.index('\n}', start) + 2
    return source[start:end] + '\n'

parts = ['import AppKit\nimport SwiftUI\nimport Combine\n']
parts.append('private enum TimelineViewportPreferences { static let zoom = 1.0 }\n')
parts.extend(declaration(grid, needle) for needle in [
    'private final class TimelineCoordinatePlane:',
    'private final class TimelineZoomState:',
    'private struct TimelineScaleLayer<',
    'private struct TimelineHostedItemCoverage:',
    'private final class TimelineHostedItemsGate:',
    'private struct TimelineHostedItemsCommit:',
    'private struct TimelineItemsScaleLayer<',
    'private enum TimelineCanvasCoverage {',
])
parts.append(declaration(metal, 'enum TimelineWaveformCoverage {'))
parts.append(declaration(scroll, 'enum TimelineLayoutDiagnostics {'))
native_start = scroll.index('private final class GridDocumentView:')
parts.append(scroll[native_start:scroll.index('\n#endif', native_start)])
parts.append(declaration(scroll, 'private final class TimelineClipView:'))
parts.append(Path('Tests/Apple/TimelineHostedItemsGateTests.swift').read_text())
Path(sys.argv[1]).write_text('\n'.join(parts))
PYTHON
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift "$gate_test_dir/main.swift" -o "$gate_test_dir/test"
CATLIVE_PROFILE_LAYOUT=0 "$gate_test_dir/test"
