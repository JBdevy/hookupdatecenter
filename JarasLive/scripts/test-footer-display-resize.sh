#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-footer-resize.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/MainView.swift').read_text()
start = source.index('private final class FooterDisplayResizeView:')
subject = source[start:source.index('\n#endif', start)]
Path(sys.argv[1]).write_text(Path('Tests/Apple/FooterDisplayResizeTests.swift').read_text().replace('// INSERT_FOOTER_RESIZE_VIEW', subject))
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
