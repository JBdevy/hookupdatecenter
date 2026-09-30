#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-text-editor.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(Path('Apple/Shared/TextItemEditor.swift').read_text() + '\n' + Path('Tests/Apple/TextItemEditorTests.swift').read_text())
PY
swiftc -swift-version 5 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/TimelineTempo.swift Apple/Shared/Theme.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
