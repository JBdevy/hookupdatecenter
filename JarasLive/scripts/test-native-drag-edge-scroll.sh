#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-drag-edge.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PYTEST'
from pathlib import Path
import sys
s=Path('Apple/Shared/GridScrollView.swift').read_text();a=s.index('@MainActor final class NativeDragEdgeScroll')
root=Path(sys.argv[1]);root.joinpath('edge.swift').write_text('import AppKit\nclass GridNativeScrollView: NSScrollView { func prepareSelectionScroll(to: CGPoint, horizontal: Bool) {} }\n'+s[a:s.index('\n#endif',a)])
root.joinpath('main.swift').write_text(Path('Tests/Apple/NativeDragEdgeScrollTests.swift').read_text())
PYTEST
swiftc -swift-version 5 "$test_dir/edge.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
