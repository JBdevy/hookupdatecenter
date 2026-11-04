#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-tab-presentation.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" "${1:-current}" <<'PY'
from pathlib import Path
import sys, subprocess
legacy = sys.argv[2] == 'legacy'
source = subprocess.check_output(['git','show','HEAD:JarasLive/Apple/Shared/JarasLiveApp.swift'],text=True) if legacy else Path('Apple/Shared/JarasLiveApp.swift').read_text()
start=source.index('@MainActor private struct DesktopWorkspaceView:')
workspace=source[start:source.index('\n#endif',start)]
source=Path('Apple/Shared/AppContainer.swift').read_text()
start=source.index('private struct DesktopProjectTabName:')
title=source[start:source.index('\nstruct DesktopProjectRoot:',start)].replace('Text(', 'TrackedTitle(')
fixture=Path('Tests/Apple/ProjectTabPresentationTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_WORKSPACE',workspace).replace('// INSERT_TITLE',title))
PY
swiftc -swift-version 5 -parse-as-library "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" "${1:-current}"
