#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-project-delete.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'EXTRACT'
from pathlib import Path
import sys
source=Path('Apple/Shared/ProjectDocuments.swift').read_text()
start=source.index('    @Published var pendingDeletion:')
subject=source[start:source.index('    func rememberProjectMedia', start)]
subject=subject.replace('UserDefaults.standard', 'testPreferences')
Path(sys.argv[1]).write_text(Path('Tests/Apple/ProjectDeletionTests.swift').read_text().replace('    // INSERT_DELETION_CONTROLLER',subject))
EXTRACT
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
