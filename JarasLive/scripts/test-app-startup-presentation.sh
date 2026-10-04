#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-startup.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/StartupPresentation.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/AppContainer.swift').read_text()
helper = source[source.index('enum AppStartupPresentation'):source.index('@MainActor final class AppContainer')]
Path(sys.argv[1]).write_text('import Foundation\n' + helper)
PY
swiftc -swift-version 5 -parse-as-library "$test_dir/StartupPresentation.swift" Tests/Apple/AppStartupPresentationTests.swift -o "$test_dir/test"
"$test_dir/test"
