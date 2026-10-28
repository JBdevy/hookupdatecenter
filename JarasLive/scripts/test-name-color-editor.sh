#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-name-color.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
editor=Path('Apple/Shared/RegionEditor.swift').read_text()
editor=editor[editor.index('struct NameColorEditor:'):editor.index('struct UnifyRegionEditor:')]
windows=Path('Apple/Shared/FXWindows.swift').read_text()
start=windows.index('private struct WorkspaceEditorDismissKey:')
dismissal=windows[start:windows.index('extension View {', start)]
typeface='// App-owned typography.'+Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.')[1]
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n'+typeface+'\n'+dismissal+'\n'+editor+'\n'+Path('Tests/Apple/NameColorEditorTests.swift').read_text())
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
    Apple/Shared/NativeTooltips.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
