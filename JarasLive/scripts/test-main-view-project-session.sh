#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-workspace-session.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" "${CATLIVE_MAIN_VIEW_SESSION_TEST_SOURCE:-Apple/Shared/MainView.swift}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[2]).read_text()
start = source.index('            .onAppear {', source.index('struct MainView:'))
appear = source[start + len('            .onAppear {'):source.index('\n            }\n            .onChange', start)]
start = source.index('            .onDisappear {', start)
disappear = source[start + len('            .onDisappear {'):source.index('\n            }\n            .alert', start)]
fixture = Path('Tests/Apple/MainViewProjectSessionTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('                // INSERT_APPEAR', appear).replace('                // INSERT_DISAPPEAR', disappear))
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
