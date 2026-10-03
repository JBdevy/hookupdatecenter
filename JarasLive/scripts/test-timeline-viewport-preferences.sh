#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-viewport-preferences.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys, uuid
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
helpers = source[source.index('enum TimelineZoomLimits'):source.index('private let markerLaneHeight')]
helpers = helpers.replace('com.hookdeveloper.catlive.viewport', 'catlive.test.viewport.' + uuid.uuid4().hex)
Path(sys.argv[1]).write_text('import SwiftUI\n' + helpers + '\n' + Path('Tests/Apple/TimelineViewportPreferencesTests.swift').read_text())
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
