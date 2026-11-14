#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-presentation-clock.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/StemAudioPlayback.swift').read_text()
start = source.index('struct AudioPresentationClock {')
end = source.index('@MainActor final class MetronomeSettings', start)
Path(sys.argv[1], 'clock.swift').write_text(source[start:end])
Path(sys.argv[1], 'main.swift').write_text(Path('Tests/Apple/AudioPresentationClockTests.swift').read_text())
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/clock.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
