#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-static-text.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/Fonts.swift" <<'PY'
from pathlib import Path
import sys
theme = Path('Apple/Shared/Theme.swift').read_text()
start = theme.index('private enum CatLiveTypeface {')
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\nimport CoreText\n' + theme[start:theme.index('\n#endif', start)])
PY
swiftc -O -swift-version 5 "$test_dir/Fonts.swift" Apple/Shared/TimelineStaticText.swift Tests/Apple/TimelineStaticTextTests.swift -o "$test_dir/test"
"$test_dir/test"
