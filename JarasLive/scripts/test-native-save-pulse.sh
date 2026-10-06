#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-save-pulse.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('Apple/Shared/TransportView.swift').read_text()
start = source.index('private struct NativeSavePulse<')
source = source[start:source.index('\n#endif', start)]
source = source.replace('private struct', 'struct').replace('private final class', 'final class')
source = source.replace('    override func hitTest', '    var layoutCount = 0\n    override func layout() { layoutCount += 1; super.layout() }\n    override func hitTest')
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + source + '\n' + Path('Tests/Apple/NativeSavePulseTests.swift').read_text())
PYTEST
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
