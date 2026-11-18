#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-reuse.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
python3 - "$fixture_dir" <<'PY'
from pathlib import Path
import sys
s=Path('Apple/Shared/TimelineGridView.swift').read_text()
a=s.index('@MainActor private final class TimelineMixerRowUpdates')
b=s.index('private struct TimelineGridContent:',a)
Path(sys.argv[1],'main.swift').write_text(Path('Tests/Apple/TimelineMixerRowReuseTests.swift').read_text()+'\n'+s[a:b])
PY
swiftc -swift-version 5 -default-isolation MainActor -I .build/out/Products/Debug -L .build/out/Products/Debug -lJarasApplication "$fixture_dir/main.swift" -o "$fixture_dir/test"
"$fixture_dir/test"
