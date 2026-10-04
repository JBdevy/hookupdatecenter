#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-grid-drop.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/GridFileDropTests.swift "$test_dir/main.swift"
python3 - "$test_dir" <<'PYDEPS'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
region = Path('Apple/Shared/RegionEditor.swift').read_text()
(folder/'environment.swift').write_text('import SwiftUI\n' + region[region.index('/// Immutable menu target:'):])
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('struct MixerResizeHandle:')
(folder/'divider.swift').write_text('import SwiftUI\nimport AppKit\n' + source[start:source.index('\n#endif', start)])
PYDEPS
swiftc -swift-version 5 "$test_dir/environment.swift" "$test_dir/divider.swift" Apple/Shared/GridScrollView.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
