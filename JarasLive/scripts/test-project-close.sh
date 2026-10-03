#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-project-close.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/JarasLiveApp.swift').read_text()
subject=source[source.index('@MainActor final class ProjectCloseGuard'):source.rindex('\n#endif')]
# Exercise the actual close controller, replacing only the dialog and external
# playback/persistence dependencies. No user project or real window is closed.
subject=subject.replace('NSAlert()', 'CloseTestAlert()')
documents=Path('Apple/Shared/ProjectDocuments.swift').read_text()
opening=documents[documents.index('    @Published var canCancelOpening'):documents.index('    @Published var status')]
opening=opening.replace('@Published ', '').replace('private func beginOpening', 'func beginOpening')
test=Path('Tests/Apple/ProjectCloseTests.swift').read_text().replace('// INSERT_CLOSE_CONTROLLER',subject).replace('// INSERT_OPENING_CONTROLLER',opening)
Path(sys.argv[1]).write_text(test)
PY
swiftc -swift-version 5 Application/Project/ProjectOpening.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
