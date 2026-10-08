#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; native body compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-native-body.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
source = source.replace('    func update(_ items: [Item]) {',
    '    var nativeBodyInkUpdatesForTest = 0\n    var nativeBodyInkInvalidationsForTest = 0\n    func update(_ items: [Item]) {\n        nativeBodyInkUpdatesForTest += 1', 1)
source = source.replace('if hadItems || !items.isEmpty { needsDisplay = true }',
    'if hadItems || !items.isEmpty { nativeBodyInkInvalidationsForTest += 1; needsDisplay = true }', 1)
def declaration(needle):
    first = source.index(needle)
    return source[first:source.index('\n}', first) + 2]

def between(start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]
parts = [between('@MainActor private struct NativeTimelineAudioBodyConfiguration', '/// Structural data changes'),
         between('private final class TimelineRenderMetadata {', '@MainActor private final class TimelineRenderMetadataCache'),
         between('@MainActor private struct TrackRowLayout {', 'private struct TimelineHeader:'),
         declaration('private struct TimelineHostedItemCoverage:'),
         declaration('private enum TimelineCanvasCoverage {')]
stubs = '''import SwiftUI
import AppKit
import Combine
import AVFoundation
import UniformTypeIdentifiers
import Metal
private enum JarasLocalization { static func string(_ value: String) -> String { value } }
private final class RecordingLaneLayout {
    static let shared = RecordingLaneLayout()
    func count(for id: UUID, existing: Int) -> Int { existing }
}
'''
probes = '''
extension NativeTimelineItemBodyInkView {
    var nativeBodyInkItemsForTest: [Item] { items }
}
extension NativeTimelineAudioBodyView {
    var waveformIDsForTest: Set<UUID> { Set(visibleWaveforms.map { $0.clip.id }) }
    var inkForTest: [NativeTimelineItemBodyInkView.Item] { bodyInk.nativeBodyInkItemsForTest }
    var inkUpdatesForTest: Int { bodyInk.nativeBodyInkUpdatesForTest }
    var inkInvalidationsForTest: Int { bodyInk.nativeBodyInkInvalidationsForTest }
    var inkValuesForTest: [String] {
        inkForTest.map { item in
            switch item.content {
            case .text(let text), .label(let text): return text.string
            case .emptyWaveform(let channels): return "channels:\(channels)"
            }
        }
    }
    var fillsForTest: MetalWaveformFrame? { fills.nativeBodyFrameForTest }
    var waveformsForTest: MetalWaveformFrame? { waveforms.nativeBodyFrameForTest }
    var fillSubmissionsForTest: Int { fills.nativeBodySubmissionsForTest }
    var waveformSubmissionsForTest: Int { waveforms.nativeBodySubmissionsForTest }
    var observesReadinessForTest: Bool { readiness != nil }
    func submitDeferredReadinessForTest() { submitWaveforms() }
    var surfaceGeometryForTest: [CGRect] {
        [frame, bounds, fills.frame, fills.bounds, waveforms.frame, waveforms.bounds, bodyInk.frame, bodyInk.bounds,
         fills.presentedContentFrame, waveforms.presentedContentFrame]
    }
}
'''
preflight = between('    @discardableResult private func prepareHostedViewport(', '    @discardableResult private func updateHostedItems')
preflight = preflight.replace('private func prepareHostedViewport', 'func prepareHostedViewport')
preflightTests = Path('Tests/Apple/TimelineNativeBodyPreflightTests.swift').read_text().replace('__NATIVE_BODY_PREFLIGHT_METHOD__', preflight)
out.joinpath('main.swift').write_text(stubs + '\n'.join(parts) + probes + Path('Tests/Apple/TimelineNativeBodyTests.swift').read_text() + '\n' + preflightTests)
renderer = Path('Apple/Shared/MetalWaveformRenderer.swift').read_text()
renderer = renderer.replace('    private var latest: MetalWaveformFrame?', '    var nativeBodySubmissionsForTest = 0\n    private var latest: MetalWaveformFrame?', 1)
renderer = renderer.replace('    func submit(_ frame: MetalWaveformFrame) {', '    func submit(_ frame: MetalWaveformFrame) {\n        nativeBodySubmissionsForTest += 1', 1)
renderer += '\nextension MetalWaveformSurface { var nativeBodyFrameForTest: MetalWaveformFrame? { latest } }\n'
out.joinpath('MetalWaveformRenderer.swift').write_text(renderer)
cache = Path('Apple/Shared/TimelineAudioWaveform.swift').read_text()
cache += '''
extension TimelineAudioWaveform {
    func pauseNativeBodyTestDecoding() { worker.suspend() }
    func resumeNativeBodyTestDecoding() { worker.resume() }
    func publishNativeBodyTestReadiness() { revision &+= 1 }
}
'''
out.joinpath('TimelineAudioWaveform.swift').write_text(cache)
selection = Path('Apple/Shared/GridSelectionInput.swift').read_text()
start = selection.index('struct GridSelectionItem {')
out.joinpath('GridSelectionGeometry.swift').write_text('import SwiftUI\n' + selection[start:selection.index('#if os(macOS)', start)])
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  Apple/Shared/TimelineRenderDiagnostics.swift Apple/Shared/TimelineVisibleClipIndex.swift \
  Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
  Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift \
  Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift \
  Application/Project/ClipRepetition.swift Application/Project/AudioFileRead.swift \
  Apple/Shared/Theme.swift "$test_dir/TimelineAudioWaveform.swift" \
  "$test_dir/MetalWaveformRenderer.swift" Apple/Shared/TimelineMetalWaveforms.swift \
  "$test_dir/GridSelectionGeometry.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
