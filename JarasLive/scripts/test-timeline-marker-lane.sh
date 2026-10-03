#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-marker-lane.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('private struct TimelineHeader:')
end = source.index('private struct RegionBoundaryOverlay:', start)
surface = source.index('private struct TimelineCanvasSurface:')
surface_end = source.index('/// Search sorted item boundaries', surface)
stub = '''import SwiftUI
import AppKit
private let markerLaneHeight: CGFloat = 16
private let tempoLaneHeight: CGFloat = 16
private let barLaneHeight: CGFloat = 16
private struct TimelineRenderKey: Equatable { var revision = 0 }
private struct TimelineTileIdentity: Equatable { var renderKey: TimelineRenderKey; var extent: Double; var light: Bool }
enum JarasLocalization { static func string(_ value: String) -> String { value } }
'''
flag = source[source.index('private func drawMarkerFlag('):]
Path(sys.argv[1]).write_text(stub + source[start:end] + source[surface:surface_end] + flag + Path('Tests/Apple/TimelineMarkerLaneTests.swift').read_text())
PY
swiftc Apple/Shared/TimelineRenderDiagnostics.swift -O -swift-version 5 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift Apple/Shared/Theme.swift Apple/Shared/TimelineStaticText.swift Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
