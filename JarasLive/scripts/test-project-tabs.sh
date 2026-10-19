#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-project-tabs.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/AppContainer.swift').read_text()
start = source.index('@MainActor final class DesktopProjectTabs')
end = source.index('\nstruct DesktopProjectTabBar:', start)
controller = source[start:end].replace('NSAlert()', 'TestAlert()')
fixture = Path('Tests/Apple/ProjectTabsTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_PROJECT_TABS', controller))
PY
swiftc -swift-version 5 -parse-as-library "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
