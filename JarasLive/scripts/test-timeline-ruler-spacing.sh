#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ruler-spacing.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Application/Project/TimelineTempo.swift').read_text()
parts = ['import SwiftUI\nimport AppKit\n']
for begin, end in [
    ('public enum ProjectTimebase:', 'public enum TempoMarkerTimebase:'),
    ('public enum TimelineTempo {', 'public struct TapTempo {'),
    ('public struct TimelineTempoSection:', 'public extension Song {'),
]:
    start = source.index(begin)
    parts.append(source[start:source.index(end, start)])
parts.append(source[source.index('public enum TimelineTimeRuler {'):])
parts.append(Path('Tests/Apple/TimelineRulerSpacingTests.swift').read_text())
Path(sys.argv[1]).write_text('\n'.join(parts))
PY
swiftc -O -swift-version 5 Apple/Shared/TimelineStaticText.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
