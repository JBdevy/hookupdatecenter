#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-section-progress.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/SmoothSeekPanel.swift').read_text()
a = source.index('private struct NativeSectionProgressBar:')
b = source.index('\n#endif', a)
prelude = 'import SwiftUI\nimport AppKit\nprivate enum JarasTheme { static let green = Color.green; static let yellow = Color.yellow }\n'
Path(sys.argv[1]).write_text(prelude + source[a:b] + '\n' + Path('Tests/Apple/SmoothSeekProgressTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
