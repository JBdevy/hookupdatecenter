#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-render-stress.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys, os
s=Path('Apple/Shared/TimelineGridView.swift').read_text()
def between(a,b): return s[s.index(a):s.index(b,s.index(a))]
parts=[between('struct TimelineDrawing:', '/// During a gain gesture'),
       between('private func drawTimelineAudioWaveform(', '\n#if os(macOS)\nimport AppKit\nstruct MixerResizeHandle:'),
       between('@MainActor private final class TrackLayoutCache {', '@MainActor private final class RegionOverlapCache {'),
       between('@MainActor private struct TrackRowLayout {', 'private struct TimelineHeader:'),
       between('private final class TimelineResolvedName:', 'private struct RegionBoundaryOverlay:'),
       between('private final class TimelineWaveformGeometry:', '/// Search sorted item boundaries'),
       between('struct TimelineRenderKey:', '/// Grid, waveform tiles')]
# The render-key definition is followed by other types unrelated to drawing.
parts[-1]=parts[-1][:parts[-1].index('\n}',parts[-1].index('struct TimelineRenderKey:'))+2]
stubs='''import SwiftUI
import AppKit
import AVFoundation
private final class RecordingLaneLayout { static let shared = RecordingLaneLayout(); func count(for id: UUID, existing: Int) -> Int { existing } }
'''
source = stubs+'\n'.join(parts)
# ImageRenderer cannot capture an embedded MTKView. This harness specifically
# exercises the production Canvas fallback; Metal has separate GPU readback tests.
source = source.replace('MetalWaveformRenderer.isSupported', 'false')
if os.environ.get('JARAS_COLOR_ISOLATION_TEST') == '1':
    start = source.index('private func drawTimelineItem(')
    body = source.index(' {', start) + 2
    source = source[:body] + '\n    TimelineColorDrawProbe.record()\n' + source[body:]
    tests = 'Tests/Apple/TimelineColorIsolationTests.swift'
else:
    tests = 'Tests/Apple/TimelineRenderStressTests.swift'
Path(sys.argv[1]).write_text(source+'\n'+Path(tests).read_text())
PY
swiftc Apple/Shared/TimelineRenderDiagnostics.swift -O -swift-version 5 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift Application/Project/ClickTrack.swift Application/Project/ClipRepetition.swift Apple/Shared/Theme.swift Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/GridSelectionInput.swift Apple/Shared/ItemGainPreview.swift Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift Apple/Shared/MetalWaveformRenderer.swift Apple/Shared/TimelineMetalWaveforms.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
