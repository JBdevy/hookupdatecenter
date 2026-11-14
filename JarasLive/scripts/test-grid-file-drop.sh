#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-grid-drop.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYDEPS'
from pathlib import Path
import sys
source = Path('Apple/Shared/GridScrollView.swift').read_text()
a = source.index('    var fileDrop: (([URL], CGPoint) -> Bool)?', source.index('final class GridNativeScrollView:'))
b = source.index('    // A committed layout clears zoomAnchor', a)
subject = 'final class GridNativeScrollView: NSScrollView {\n' + source[a:b] + '\n}\n'
tests = Path('Tests/Apple/GridFileDropTests.swift').read_text().replace('let application = DropTestApplication.shared', 'MainActor.assumeIsolated {\nlet application = DropTestApplication.shared', 1) + '\n}\n'
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\n' + subject + tests)
PYDEPS
swiftc -swift-version 5 -target "${CATLIVE_TEST_ARCH:-$(uname -m)}-apple-macos12.0" Apple/Shared/NativeTimelineInputGate.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
