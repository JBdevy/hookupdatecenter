#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-tempo-focus.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Apple/Shared/TransportView.swift').read_text()
start = source.index('private final class TempoFieldOutsideClickView')
end = source.index('\n#endif', start)
Path(sys.argv[1]).write_text('import AppKit\n' + source[start:end] + '\n' + Path('Tests/Apple/TempoFieldFocusTests.swift').read_text())
PYTHON
swiftc "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
