#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; marker geometry compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-marker-targets.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
model = Path('Application/Project/ProjectModels.swift').read_text()
model = model[model.index('public struct TimelineMarker:'):model.index('public struct Song:')]
tempo = Path('Application/Project/TimelineTempo.swift').read_text()
tempo = tempo[:tempo.index('public struct ProjectTimeSettings:')]
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
source = source[source.index('private final class MarkerTargetLabelWidths'):source.index('private struct MarkerEditTargets:')]
tests = Path('Tests/Apple/MarkerTargetGeometryTests.swift').read_text()
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + tempo + model + source + tests)
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
