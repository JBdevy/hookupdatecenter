#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-close.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
source = Path('Apple/Shared/ProjectDocuments.swift').read_text()
start = source.index('    func closeNativeProject(suspendAudio:')
end = source.index('\n    #endif', start)
fixture = Path('Tests/Apple/NativeProjectCloseTests.swift').read_text()
(p/'document.swift').write_text(fixture.replace('    // PRODUCTION_CLOSE', source[start:end]))
(p/'waveform.swift').write_text(Path('Application/Project/AudioFileRead.swift').read_text() + '\n' +
    Path('Apple/Shared/TimelineAudioWaveform.swift').read_text() + '\n' +
    Path('Tests/Apple/WaveformProjectCloseTests.swift').read_text())
PY
cp "$test_dir/document.swift" "$test_dir/main.swift"
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/document"
"$test_dir/document"
cp "$test_dir/waveform.swift" "$test_dir/main.swift"
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/waveform"
"$test_dir/waveform"
