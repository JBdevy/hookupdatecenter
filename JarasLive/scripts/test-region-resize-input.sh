#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-region-input.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/RegionResizeInputTests.swift "$test_dir/main.swift"
python3 - "$test_dir/inputs.swift" <<'PYINPUT'
from pathlib import Path
import sys
source = Path('Apple/Shared/RegionEditor.swift').read_text()
start = source.index('struct RegionRightClick:')
end = source.index('\n#endif', source.index('final class MarkerEditClickView:', start))
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + source[start:end])
PYINPUT
swiftc -swift-version 5 Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/RightClickRouting.swift "$test_dir/inputs.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
