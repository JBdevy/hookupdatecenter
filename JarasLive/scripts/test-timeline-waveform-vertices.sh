#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-waveform-vertices.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineAudioWaveform.swift').read_text()
decode = '        do { audio.framePosition = start; try AudioFileRead.read(audio, into: buffer, frameCount: count) }'
assert source.count(decode) == 1, 'PCM page decoder instrumentation must identify exactly one physical read'
source = source.replace(decode, '        if shouldFailPCMPageForTest(url, start: start) { return nil }\n' +
                       '        recordPCMPageReadForTest(url, start: start, frames: Int(count))\n' + decode)
Path(sys.argv[1]).write_text(Path('Application/Project/AudioFileRead.swift').read_text() + '\n' + source + '\n' +
                           Path('Tests/Apple/TimelineWaveformVertexTests.swift').read_text())
PY
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
