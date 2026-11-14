#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-copy-selection.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swift build --product JarasApplication --jobs 2 >/dev/null
products="$(swift build --show-bin-path)"
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('    private var selectedTrack: UUID?')
selection = source[start:source.index('    @State private var addingTrack', start)]
fixture = Path('Tests/Apple/TrackCopySelectionPresentationTests.swift').read_text()
metadata_start = source.index('private func mixerMetadata(')
metadata = source[metadata_start:source.index('\n#if os(macOS)', metadata_start)]
Path(sys.argv[1]).write_text(fixture.replace('    // INSERT_PRODUCTION_SELECTION', selection).replace('// INSERT_PRODUCTION_MIXER_METADATA', metadata))
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" -I "$products" -L "$products" -lJarasApplication "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
