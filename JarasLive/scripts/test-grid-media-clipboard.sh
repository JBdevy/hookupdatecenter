#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-media-paste.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/ProjectDocuments.swift').read_text()
start = source.index('@MainActor final class GridMediaClipboard')
helper = source[start:source.index('\n#endif', start)]
Path(sys.argv[1]).write_text('import AppKit\nimport UniformTypeIdentifiers\nimport AVFoundation\n' + helper + '\n' + Path('Tests/Apple/GridMediaClipboardTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
