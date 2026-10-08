#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-visibility.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TrackMixerRow.swift').read_text()
geometry = source[source.index('struct TrackMixerHeightGeometry {'):source.index('private struct LegacyMixerHeightKey:')]
start = source.index('private final class TrackMixerNativeContent {')
end = source.index('\n#endif', start)
fixture = Path('Tests/Apple/TrackMixerVisibilityTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_NATIVE_TRACK_MIXER_VISIBILITY', geometry + source[start:end]))
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
