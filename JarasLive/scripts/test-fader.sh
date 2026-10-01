#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-fader.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Apple/Shared/TrackMixerRow.swift').read_text()
start = source.index('private final class DirectVolumeSliderView')
end = source.index('\n#endif', start)
tests = Path('Tests/Apple/FaderInteractionTests.swift').read_text()
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nprivate enum JarasTheme { static let green = Color.green; static let yellow = Color.yellow }\n' + source[start:end] + '\n' + tests)
PYTHON
swift "$build_dir/main.swift"
