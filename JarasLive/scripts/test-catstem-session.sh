#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catstem-session.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/session.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/CatStemSeparation.swift').read_text()
start=source.index('@MainActor final class CatStemSession')
end=source.index('struct CatStemProgressView:',start)
fixture=Path('Tests/Apple/CatStemSessionLifecycleTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_SESSION',source[start:end]))
PY
swiftc -swift-version 5 -parse-as-library "$build_dir/session.swift" -o "$build_dir/session-test"
"$build_dir/session-test"
