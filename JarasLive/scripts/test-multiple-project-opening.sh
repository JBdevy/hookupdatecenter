#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-multiple-opening.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
python3 - "$fixture_dir/fixture.swift" <<'PY'
from pathlib import Path
import sys
s=Path('Apple/Shared/ProjectDocuments.swift').read_text()
a=s.index('@MainActor final class MultipleProjectOpening:')
b=s.index('private struct RecentProjectCheckboxStyle:',a)
Path(sys.argv[1]).write_text(Path('Tests/Apple/MultipleProjectOpeningTests.swift').read_text()+'\n'+s[a:b])
PY
swiftc -swift-version 5 -parse-as-library "$fixture_dir/fixture.swift" -o "$fixture_dir/test"
"$fixture_dir/test"
