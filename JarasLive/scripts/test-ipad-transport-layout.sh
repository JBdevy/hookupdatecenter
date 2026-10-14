#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-transport.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/AdvancedView.swift').read_text()
a = source.index('enum IpadTransportControl:')
b = source.index('private struct AdvancedTransportSettings:', a)
Path(sys.argv[1]).write_text('import Foundation\n' + source[a:b] + Path('Tests/Apple/IpadTransportLayoutTests.swift').read_text())
PY
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
