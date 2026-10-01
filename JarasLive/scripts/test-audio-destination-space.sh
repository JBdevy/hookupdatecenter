#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-disk-space.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Apple/Shared/AudioExportView.swift').read_text().split('// MARK: - Destination disk reserve')[1]
tests = Path('Tests/Apple/AudioDestinationSpaceTests.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\nimport AppKit\n' + source + tests)
PYTHON
swift "$test_dir/main.swift"
