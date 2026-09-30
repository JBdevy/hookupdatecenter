#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-sidebar-divider.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
fx = Path('Apple/Shared/FXEditor.swift').read_text()
text = Path('Apple/Shared/TextItemEditor.swift').read_text()
region = Path('Apple/Shared/RegionEditor.swift').read_text()
track_environment = region[region.index('/// Immutable menu target:'):]
(folder/'environment.swift').write_text(fx[:fx.index('enum FXModelLookup')] + text[:text.index('/// The draft')] + track_environment)
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('struct MixerResizeHandle:')
end = source.index('\n#endif', start)
(folder/'divider.swift').write_text('import SwiftUI\nimport AppKit\n' + source[start:end])
(folder/'main.swift').write_text(Path('Tests/Apple/SidebarDividerInteractionTests.swift').read_text())
PY
swiftc -swift-version 5 Apple/Shared/GridScrollView.swift "$test_dir/environment.swift" "$test_dir/divider.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
