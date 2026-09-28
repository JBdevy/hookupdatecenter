#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-mixer-lifecycle.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
fx = Path('Apple/Shared/FXEditor.swift').read_text()
text = Path('Apple/Shared/TextItemEditor.swift').read_text()
(folder/'environment.swift').write_text(fx[:fx.index('enum FXModelLookup')] + text[:text.index('/// The draft')])
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('private final class TimelineScrollPosition')
end = source.index('/// Move the existing header surface',start)
(folder/'main.swift').write_text('import SwiftUI\n' + source[start:end] + '\n' + Path('Tests/Apple/TimelineMixerLifecycleTests.swift').read_text())
PY
swiftc -swift-version 5 Apple/Shared/GridScrollView.swift "$test_dir/environment.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
