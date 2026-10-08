#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; native header compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-native-header.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
def between(a,b):
 start=source.index(a)
 return source[start:source.index(b,start)]
parts = [between('/// The closed header owns no SwiftUI zoom graph.', '@MainActor private struct NativeTimelineBaseStyle'),
 between('private enum TimelineHeaderViewport', 'private struct TimelineStaticHeaderIdentity'),
 between('private final class MarkerTargetLabelWidths', 'private struct MarkerEditTargets'),
 between('private final class TimelineResolvedName', 'private struct RegionBoundaryOverlay')]
# Instrument the extracted fixture only; production carries no test counters.
# Instrument layer properties only inside the header drawing class. Native
# input shape layers keep their independent selection/hover lifecycle.
header_start = parts[0].index('@MainActor private final class NativeTimelineHeaderView:')
header_end = parts[0].index('/// Region commands are structural', header_start)
header = parts[0][header_start:header_end].replace('CALayer()', 'HeaderProbeLayer()').replace('CAShapeLayer()', 'HeaderProbeShapeLayer()')
parts[0] = parts[0][:header_start] + header + parts[0][header_end:]
parts[0] = parts[0].replace('    private var inputOrder: [UUID] = []', '    var markerConfigurationsForTest = 0\n    var regionProjectionsForTest = 0\n    var redrawRequestsForTest = 0\n    private var inputOrder: [UUID] = []', 1)
parts[0] = parts[0].replace('        regionsInput.project(scale: scale, viewport: tile)', '        regionProjectionsForTest += 1\n        regionsInput.project(scale: scale, viewport: tile)', 1)
parts[0] = parts[0].replace('    private func configure(_ view: MarkerEditClickView, marker: TimelineMarker, scale: CGFloat) {', '    private func configure(_ view: MarkerEditClickView, marker: TimelineMarker, scale: CGFloat) {\n        markerConfigurationsForTest += 1', 1)
parts[0] = parts[0].replace('    private func updateDrawingLayers() {', '    private func updateDrawingLayers() {\n        redrawRequestsForTest += 1', 1)
parts[0] = parts[0].replace('        private var image: CGImage?', '        var assignmentsForTest = 0\n        private var image: CGImage?', 1)
parts[0] = parts[0].replace('if self.image !== image { self.image = image;', 'if self.image !== image { assignmentsForTest += 1; self.image = image;', 1)
probes = '''
extension NativeTimelineHeaderView {
    var tileForTest: CGRect { tile }
    var previewForTest: TimelineMarker? { preview }
    var drawingForTest: CALayer { drawingLayer }
    var retainedRegionsForTest: [UUID: CALayer] { regionLayers.mapValues { $0.root } }
    var retainedMarkersForTest: [UUID: CALayer] { markerLayers.mapValues { $0.root } }
    var retainedBoundariesForTest: [UUID: CALayer] { boundaryLayers.mapValues { $0.root } }
    var textAssignmentsForTest: Int {
        regionLayers.values.reduce(0) { $0 + $1.identifier.assignmentsForTest + $1.name.assignmentsForTest } +
            markerLayers.values.reduce(0) { $0 + $1.name.assignmentsForTest }
    }
    var viewportForTest: CGRect { viewport }
    func markerForTest(_ id: UUID) -> MarkerEditClickView? { markerInputs[id] }
    var regionViewForTest: NativeTimelineRegionTargetsView { regionsInput }
    var markersForTest: [(UUID, CGRect, String)] { projectedMarkers.map { ($0.marker.id, $0.rect, $0.label) } }
    var identifiersForTest: [String] { regions.map(\\.identifier) }
    var colorsForTest: [UInt32] { regions.map(\\.color) }
}
'''
Path(sys.argv[1], 'main.swift').write_text('import AppKit\nimport SwiftUI\nimport CoreText\nprivate let markerLaneHeight: CGFloat = 16\n'+'\n'.join(parts)+probes+Path('Tests/Apple/TimelineNativeHeaderTests.swift').read_text()+'\n'+Path('Tests/Apple/TimelineHeaderLayerStateTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
  Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift \
  Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift \
  Application/Project/TimelineTempo.swift Apple/Shared/Theme.swift Apple/Shared/NativeTooltips.swift \
  Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/RightClickRouting.swift \
  Apple/Shared/RegionEditor.swift Apple/Shared/TimelineStaticText.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
