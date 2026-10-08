#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; base projection tests deferred." >&2
  exit 2
fi
projection_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-base-projection.XXXXXX")"
trap 'rm -rf "$projection_test_dir"' EXIT
python3 - "$projection_test_dir/main.swift" <<'PYTHON'
from pathlib import Path
import re, sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
tempo = Path('Application/Project/TimelineTempo.swift').read_text()

def declaration(needle):
    start = source.index(needle)
    return source[start:source.index('\n}', start) + 2]

parts = ['import AppKit\nimport SwiftUI\n']
for begin, end in [
    ('public enum ProjectTimebase:', 'public enum TempoMarkerTimebase:'),
    ('public enum TimelineTempo {', 'public struct TapTempo {'),
    ('public struct TimelineTempoSection:', 'public extension Song {'),
]:
    start = tempo.index(begin)
    parts.append(tempo[start:tempo.index(end, start)])
ticks = tempo[tempo.index('public enum TimelineTimeRuler {'):]
ticks = ticks.replace('public enum TimelineTimeRuler {', 'public enum TimelineTimeRuler {\n    static var fixtureTickBuilds = 0')
ticks = ticks.replace('minimumLabelSpacing: Double? = nil) -> [Tick] {', 'minimumLabelSpacing: Double? = nil) -> [Tick] {\n        fixtureTickBuilds += 1')
parts.append(ticks)
for begin in ['private struct TimelineNativeGridBand {', 'private struct TimelineNativeRuler:']:
    start = source.index(begin)
    native = source[start:source.index('\n#endif', start)]
    for cls, content in [('TimelineNativeGridView', 'TimelineNativeGridBackdrop'), ('TimelineNativeRulerView', 'TimelineNativeRuler')]:
        if 'private final class ' + cls not in native:
            continue
        native = native.replace('private final class ' + cls + ': NSView {', 'private final class ' + cls + ': NSView {\n    var fixtureUpdates = 0')
        native, count = re.subn(r'(func update\(_ \w+: ' + content + r'\) \{)', r'\1\n        fixtureUpdates += 1', native)
        assert count == 1, 'expected exactly one instrumented update for ' + cls
    parts.append(native)
parts.extend(declaration(needle) for needle in ['private enum TimelineCanvasCoverage {', 'private enum TimelineHeaderViewport {'])
controller = source[source.index('@MainActor private final class NativeTimelineBaseController'):]
key_start = controller.index('    private struct Projection: Equatable {')
key_end = controller.index('    private(set) var pixelsPerSecond:', key_start)
key = controller[key_start:key_end]
project_start = controller.index('        let tile = TimelineCanvasCoverage.preparedRect(visibleRect: viewport,')
project_end = controller.index('        audioBody.project(', project_start)
projection = controller[project_start:project_end]
fixture = Path('Tests/Apple/TimelineBaseProjectionTests.swift').read_text()
fixture = fixture.replace('PRODUCTION_PROJECTION_STATE', key).replace('PRODUCTION_TILE_PROJECTION', projection)
parts.append(fixture)
Path(sys.argv[1]).write_text('\n'.join(parts))
PYTHON
swiftc -swift-version 5 Apple/Shared/TimelineStaticText.swift "$projection_test_dir/main.swift" -o "$projection_test_dir/test"
"$projection_test_dir/test"
