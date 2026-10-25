#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-empty-mixer.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('private struct TimelineEmptyMixerInput:')
end = source.index('\n#endif', start)
fixture = Path('Tests/Apple/EmptyTrackMixerSelectionTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// PRODUCTION_EMPTY_MIXER_INPUT', source[start:end]))
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
