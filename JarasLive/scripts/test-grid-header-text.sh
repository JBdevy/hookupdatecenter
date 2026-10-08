#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; header text compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-grid-header-text.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/GridSelectionInput.swift').read_text()
item=source[source.index('struct GridSelectionItem {'):source.index('/// Immutable item metadata')]
cache=source[source.index('enum GridSelectionHeaderText {'):source.index('struct GridSelectionInput: NSViewRepresentable')]
draw='                let pixels = CGSize(width: size.width * scale.width, height: size.height * scale.height)'
assert cache.count(draw) == 1, 'Update the rasterization probe after a source change'
cache=cache.replace(draw, '                GridHeaderRasterProbe.count += 1\n'+draw)
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nimport CoreText\n'+item+'\n'+cache+'\n'+Path('Tests/Apple/GridHeaderTextTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
