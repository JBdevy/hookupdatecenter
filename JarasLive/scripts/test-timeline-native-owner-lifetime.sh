#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-owner.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
storage = next(line.strip() for line in source.splitlines() if 'private var nativeBase = NativeTimelineBaseController()' in line)
fixture = Path('Tests/Apple/TimelineNativeOwnerLifetimeTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// PRODUCTION_NATIVE_OWNER_STORAGE', storage))
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
