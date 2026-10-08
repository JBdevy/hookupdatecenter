#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; metadata compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-render-metadata.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('private final class TimelineRenderMetadata {')
end = source.index('/// During a gain gesture', start)
key = source.index('struct TimelineRenderKey:')
key_end = source.index('\n}', key) + 2
tests = Path('Tests/Apple/TimelineRenderMetadataTests.swift').read_text()
tests += '\n' + Path('Tests/Apple/TimelineVisibleClipMetadataTests.swift').read_text()
(folder / 'main.swift').write_text('import Foundation\n' + source[start:end] + source[key:key_end] + '\n' + tests)
tempo = Path('Application/Project/TimelineTempo.swift').read_text()
for signature, counter in [
    ('func tempoSections(until end: Double) -> [TimelineTempoSection] {', 'sections'),
    ('func tempoAudioSegments(_ clip: AudioClip, sections: [TimelineTempoSection]? = nil) -> [AudioClip] {', 'fragments'),
]:
    assert tempo.count(signature) == 1
    tempo = tempo.replace(signature, signature + '\n        TimelineMetadataWorkProbe.record(.' + counter + ')')
(folder / 'TimelineTempo.swift').write_text(tempo)
PY
swiftc -O -swift-version 5 \
  Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
  Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift \
  Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift \
  Application/Project/ClipRepetition.swift "$test_dir/TimelineTempo.swift" \
  Apple/Shared/TimelineVisibleClipIndex.swift \
  "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
