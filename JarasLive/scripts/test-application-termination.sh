#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
termination_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-termination.XXXXXX")"
trap 'rm -rf "$termination_test_dir"' EXIT
python3 - "$termination_test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/JarasLiveApp.swift').read_text()
subject=source[source.index('@MainActor final class JarasApplicationDelegate'):source.index('@MainActor private final class ClosingLogo')]
test=Path('Tests/Apple/ApplicationTerminationTests.swift').read_text().replace('// INSERT_APPLICATION_DELEGATE',subject)
Path(sys.argv[1]).write_text(test)
PY
swiftc -swift-version 5 "$termination_test_dir/main.swift" -o "$termination_test_dir/test"
"$termination_test_dir/test"
