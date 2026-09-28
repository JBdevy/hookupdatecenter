#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-grid-hosting.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/environment.swift" <<'PY'
from pathlib import Path
import sys
fx = Path('Apple/Shared/FXEditor.swift').read_text()
text = Path('Apple/Shared/TextItemEditor.swift').read_text()
Path(sys.argv[1]).write_text(fx[:fx.index('enum FXModelLookup')] + text[:text.index('/// The draft')])
PY
cp Tests/Apple/GridHostingIntegrationTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/GridSelectionInput.swift Apple/Shared/GridScrollView.swift "$test_dir/environment.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
