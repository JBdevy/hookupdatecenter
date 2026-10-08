#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then echo "Measurement active; deferring"; exit 2; fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-metal-scene.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/TimelineMetalSceneTests.swift "$test_dir/main.swift"
python3 - "$test_dir/TimelineAudioWaveform.swift" <<'PYCOUNT'
from pathlib import Path
import sys
s=Path('Apple/Shared/TimelineAudioWaveform.swift').read_text()
s=s.replace('    func header(_ url: URL, refresh: Bool = false, sourcePath: String? = nil) -> Header? {', '    private(set) var headerLookupsForSceneTest = 0\n    func header(_ url: URL, refresh: Bool = false, sourcePath: String? = nil) -> Header? {\n        headerLookupsForSceneTest += 1')
Path(sys.argv[1]).write_text(s)
PYCOUNT
cat >> "$test_dir/TimelineAudioWaveform.swift" <<'SWIFT'
extension TimelineAudioWaveform {
    func replaceHeaderForSceneTest(_ value: Header, url: URL, publish: Bool) {
        headers.setObject(value, forKey: url.path as NSString)
        if publish { revision &+= 1 }
    }
    func evictVertexBlocksForSceneTest() { vertexBlocks.removeAllObjects() }
    func advanceRevisionForSceneTest() { revision &+= 1 }
    func pendingCountForSceneTest() -> Int { lock.lock(); defer { lock.unlock() }; return pending.count }
}
SWIFT
cp Apple/Shared/TimelineMetalWaveforms.swift "$test_dir/TimelineMetalWaveforms.swift"
cat >> "$test_dir/TimelineMetalWaveforms.swift" <<'SWIFT'
extension TimelineWaveformVertexOwner {
    var pinnedCountForSceneTest: Int { pinned.count }
}
SWIFT
python3 - "$test_dir/GridSelectionGeometry.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/GridSelectionInput.swift').read_text()
start = source.index('struct GridSelectionItem {')
selection = source[start:source.index('#if os(macOS)', start)]
Path(sys.argv[1]).write_text('import SwiftUI\n' + selection)
PY
swiftc Apple/Shared/TimelineRenderDiagnostics.swift -O -swift-version 5 \
  Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
  Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift \
  Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift \
  Application/Project/ClipRepetition.swift Application/Project/AudioFileRead.swift "$test_dir/TimelineAudioWaveform.swift" \
  Apple/Shared/MetalWaveformRenderer.swift "$test_dir/TimelineMetalWaveforms.swift" \
  "$test_dir/GridSelectionGeometry.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
