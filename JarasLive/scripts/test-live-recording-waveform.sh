#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-live-waveform.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/Live.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/LiveRecordingPreview.swift').read_text()
source=source[source.index('final class LiveRecordedWaveform'):]
Path(sys.argv[1]).write_text('import SwiftUI\nimport AVFoundation\nimport Darwin\n@MainActor final class LiveRecordingPreview: ObservableObject { static let shared = LiveRecordingPreview() }\n'+source)
PY
cp Tests/Apple/LiveRecordingWaveformTests.swift "$test_dir/main.swift"
swiftc -O -swift-version 5 Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift "$test_dir/Live.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
