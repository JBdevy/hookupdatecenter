#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; header compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-waveform-header.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('Apple/Shared/TimelineAudioWaveform.swift').read_text()
normalization = '            resolvedURL = url.standardizedFileURL\n'
assert source.count(normalization) == 1, 'Update the targeted header normalization probe after a source change'
source = source.replace(normalization, '            resolvedURL = WaveformHeaderNormalizationProbe.normalize(url)\n')
source += '''
// Test-only access to the existing pinned project cache and NSCache eviction.
extension TimelineAudioWaveform {
    func installPinnedHeaderForTesting(_ header: Header, path: String) {
        installProjectCache(headers: [path: header], overviews: [:], sources: [:])
        headers.removeAllObjects()
    }
}
'''
(folder / 'TimelineAudioWaveform.swift').write_text(source)
(folder / 'main.swift').write_text(Path('Tests/Apple/TimelineWaveformHeaderTests.swift').read_text())
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" Application/Project/AudioFileRead.swift "$test_dir/TimelineAudioWaveform.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
