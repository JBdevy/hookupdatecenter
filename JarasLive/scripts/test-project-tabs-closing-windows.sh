#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-tabs-closing.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.cpp" <<'PY'
from pathlib import Path
import sys
workspace = Path('Windows/Source/Workspace.cpp').read_text()
workspace = workspace[workspace.index('void Workspace::requestClose('):workspace.index('\nvoid Workspace::capture(')]
application = Path('Windows/Source/Main.cpp').read_text()
application = application[application.index('    void requestAllProjectsClosing('):application.index('    bool closingProjects = false;')]
fixture = Path('Tests/Core/ProjectTabsClosingTests.cpp').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_WORKSPACE_CLOSE', workspace).replace('// INSERT_APPLICATION_CLOSE', application))
PY
clang++ -std=c++17 -O1 -g -fsanitize=address,undefined "$test_dir/main.cpp" -o "$test_dir/test"
"$test_dir/test"
