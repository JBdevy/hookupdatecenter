#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-fader-mapping.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/ControlMappings.swift').read_text()
start = source.index('private final class MappingClickView:')
end = source.index('\n#endif', start)
Path(sys.argv[1]).write_text('import AppKit\n' + source[start:end] + '\n' + Path('Tests/Apple/FaderMappingHitAreaTests.swift').read_text())
PY
swiftc -swift-version 5 Apple/Shared/RightClickRouting.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
